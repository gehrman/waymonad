{-
waymonad A wayland compositor in the spirit of xmonad
Copyright (C) 2017  Markus Ongyerth

This library is free software; you can redistribute it and/or
modify it under the terms of the GNU Lesser General Public
License as published by the Free Software Foundation; either
version 2.1 of the License, or (at your option) any later version.

This library is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
Lesser General Public License for more details.

You should have received a copy of the GNU Lesser General Public
License along with this library; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA

Reach us at https://github.com/ongy/waymonad
-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE LambdaCase #-}
module Output
    ( handleOutputAdd
    , handleOutputRemove
    , OutputAddEvent (..)
    , Output (..)
    , getOutputId
    , outputFromWlr
    , findMode
    , setOutputDirty
    )
where

import Control.Exception (bracket_)
import Control.Monad (forM_, forM, filterM, void, when, join)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Foldable (maximumBy, minimumBy)
import Data.Function (on)
import Data.IORef (IORef, readIORef, modifyIORef)
import Data.List ((\\), sortOn, find)
import Data.Map (Map)
import Data.Maybe (listToMaybe, fromJust, maybeToList)
import Data.Monoid (Any (..), (<>))
import Data.Ratio (Ratio, (%))
import Data.Set (Set)
import Data.Text (Text)
import Data.Word (Word32)
import Foreign.Ptr (Ptr, ptrToIntPtr)
import Foreign.Storable (Storable(peek))
import System.IO (hPutStrLn, stderr)

import Graphics.Wayland.Server (callbackDone)

import Graphics.Wayland.Resource (resourceDestroy)
import Graphics.Wayland.WlRoots.Box (WlrBox(..), Point (..))
import Graphics.Wayland.WlRoots.Output
    ( WlrOutput
    , OutputMode (..)
    , setOutputMode
    , getModes
    , getTransMatrix
    , swapOutputBuffers
    , makeOutputCurrent
    , getOutputName
    , getOutputScale
    , setOutputScale

    , getOutputNeedsSwap
    , setOutputNeedsSwap
    )
import Graphics.Wayland.WlRoots.OutputLayout
    ( WlrOutputLayout
    , addOutput
    , addOutputAuto
    , outputIntersects
-- TODO: I think wlroots made this simpler
    , layoutOuputGetPosition
    , layoutGetOutput
    )
import Graphics.Wayland.WlRoots.Render
    ( Renderer
    , renderWithMatrix
    , isTextureValid
    , doRender
    )
import Graphics.Wayland.WlRoots.Render.Matrix
    ( withMatrix
    , matrixTranslate
    , matrixScale
    , matrixMul
    )
import Graphics.Wayland.WlRoots.Surface
    ( WlrSurface
    , surfaceGetSubs
    , subSurfaceGetBox
    , subSurfaceGetSurface
    , getCurrentState
    , callbackGetCallback
    , callbackGetResource
    , surfaceGetCallbacks
    , withSurfaceMatrix
    , surfaceGetTexture
    , surfaceGetScale
    , surfaceHasDamage
    )

import Waymonad (makeCallback2)
import Waymonad.Types (Compositor (..))
import Config (configOutputs)
import qualified Config.Box as C (Point (..))
import Config.Output (OutputConfig (..), Mode (..))
--import Input (Input(inputXCursor, inputCursor))
--import Input.Cursor (cursorRoots)
import Input.Seat (Seat(seatLoadScale))
import Shared (FrameHandler)
import Utility (whenJust, doJust)
import View
    ( View
    , getViewSurface
    , renderViewAdditional
    , getViewBox
    , viewGetScale
    , viewGetLocal
    , viewIsDirty
    , viewSetClean
    )
import ViewSet (WSTag (..))
import Waymonad
    ( Way
    , WayBindingState (..)
    , getState
    , EventClass
    , sendEvent
    , getSeats
    )
import qualified Data.IntMap.Strict as IM
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import qualified Data.Text as T
import qualified Data.Text.IO as T

data Output = Output
    { outputRoots :: Ptr WlrOutput
    , outputName  :: Text
    }

instance Show Output where
    show Output {outputName = name} = T.unpack name

instance Eq Output where
    Output {outputRoots = left} == Output {outputRoots = right} = left == right

instance Ord Output where
    Output {outputRoots = left} `compare` Output {outputRoots = right} = left `compare` right

ptrToInt :: Num b => Ptr a -> b
ptrToInt = fromIntegral . ptrToIntPtr

renderOn :: Ptr WlrOutput -> Ptr Renderer -> IO a -> IO a
renderOn output rend act = bracket_
    (makeOutputCurrent output)
    (swapOutputBuffers output)
    (doRender rend output act)

outputHandleSurface :: Compositor -> Double -> Ptr WlrOutput -> Ptr WlrSurface -> Float -> WlrBox -> IO ()
outputHandleSurface comp secs output surface scaleFactor box = do
    outputScale <- getOutputScale output
    surfScale <- fromIntegral <$> surfaceGetScale surface
    let localScale = (outputScale / surfScale) * scaleFactor
    texture <- surfaceGetTexture surface
    isValid <- isTextureValid texture
    when isValid $ withMatrix $ \trans -> withMatrix $ \scale -> withMatrix $ \final -> do
            let x = fromIntegral (boxX box) * outputScale
                y = fromIntegral (boxY box) * outputScale

            matrixTranslate trans x y 0
            matrixScale scale localScale localScale 1
            matrixMul trans scale final
            withSurfaceMatrix surface (getTransMatrix output) final $ \mat ->
                renderWithMatrix (compRenderer comp) texture mat

            callbacks <- surfaceGetCallbacks =<< getCurrentState surface
            forM_ callbacks $ \callback -> do
                cb <- callbackGetCallback callback
                callbackDone cb (floor $ secs * 1000)
                res <- callbackGetResource callback
                resourceDestroy res

            subs <- surfaceGetSubs surface
            forM_ subs $ \sub -> do
                sbox <- subSurfaceGetBox sub
                subsurf <- subSurfaceGetSurface sub
                outputHandleSurface
                    comp
                    secs
                    output
                    subsurf
                    scaleFactor
                    sbox{ boxX = floor (fromIntegral (boxX sbox) * scaleFactor * outputScale) + boxX box
                        , boxY = floor (fromIntegral (boxY sbox) * scaleFactor * outputScale) + boxY box
                        , boxWidth = floor $ fromIntegral (boxWidth sbox) * scaleFactor
                        , boxHeight = floor $ fromIntegral (boxHeight sbox) * scaleFactor
                        }

outputHandleView :: Compositor -> Double -> Ptr WlrOutput -> View -> WlrBox -> IO (IO ())
outputHandleView comp secs output view box = doJust (getViewSurface view) $ \surface -> do
    viewSetClean view
    scale <- viewGetScale view
    local <- viewGetLocal view
    let lBox = box { boxX = boxX box + boxX local, boxY = boxY box + boxY local}
    outputHandleSurface comp secs output surface scale lBox
    pure $ renderViewAdditional (\v b ->
        void $ outputHandleSurface
            comp
            secs
            output
            v
            scale
            b   { boxX = floor (fromIntegral (boxX b) * scale) + boxX lBox
                , boxY = floor (fromIntegral (boxY b) * scale) + boxY lBox
                , boxWidth = floor $ fromIntegral (boxWidth b) * scale
                , boxHeight = floor $ fromIntegral (boxHeight b) * scale
                }
        )
        view


frameHandler
    :: WSTag a
    => Double
    -> Ptr WlrOutput
    -> Way a ()
frameHandler secs output = do
    comp <- wayCompositor <$> getState
    (Point ox oy) <- liftIO (layoutOuputGetPosition =<< layoutGetOutput (compLayout comp) output)
    viewsM <- IM.lookup (ptrToInt output) <$> (liftIO . readIORef . wayBindingCache =<< getState)
    floats <- filterM (intersects $ compLayout comp) . S.toList =<< (liftIO . readIORef . wayFloating =<< getState)
    
--    needsRedraw <- liftIO $ mapM (\v -> getViewSurface v >>= (\case
--        Nothing -> pure mempty
--        Just surf -> Any <$> surfaceHasDamage surf)) (fmap fst $ join $ maybeToList viewsM)
    needsRedraw <- mapM (fmap Any . viewIsDirty) (fmap fst $ join $ maybeToList viewsM)
    needsSwap <- liftIO $ getOutputNeedsSwap output
    when (getAny (foldr (<>) mempty needsRedraw) || needsSwap) $ liftIO $ renderOn output (compRenderer comp) $ do
        hPutStrLn stderr "Going to render on output"
        case viewsM of
            Nothing -> pure ()
            Just wsViews -> do
                overs <- mapM (uncurry $ outputHandleView comp secs output) wsViews
                sequence_ overs
        forM_ floats $ \view -> do
            (WlrBox x y w h) <- getViewBox view
            let box = WlrBox (x - ox) (y - oy) w h
            outputHandleView comp secs output view box

    where  intersects layout view = liftIO (outputIntersects layout output =<< getViewBox view)

pickMode
    :: MonadIO m
    => Ptr WlrOutput
    -> Maybe Mode
    -> m (Maybe (Ptr OutputMode))
-- If there's no config, just pick the "last" mode, it's the native resolution
pickMode output Nothing = liftIO $ do
    modes <- getModes output
    pure $ listToMaybe $ reverse modes
pickMode output (Just cfg) = liftIO $ do
    modes <- getModes output
    paired <- forM modes $ \x -> do
        marshalled <- peek x
        pure (marshalled, x)
    -- First try to find modes that match *exactly* on resolution
    let matches = map snd . sortOn (refreshDist . fst) $ filter (sameResolution . fst) paired
    let ratio = map snd . sortOn (\m -> (resDist $ fst m, refreshDist $ fst m)) $ filter (sameAspect . fst) paired

    -- TODO: Sanitize this
    pure . listToMaybe . reverse $ modes ++ ratio ++ matches
    where   sameResolution :: OutputMode -> Bool
            sameResolution mode =
                fromIntegral (modeWidth mode) == modeCWidth cfg
                && fromIntegral (modeHeight mode) == modeCHeight cfg
            refreshDist :: OutputMode -> Int -- Cast to Int, so we don't get wrapping arithmetic, *should* be big enough!
            refreshDist mode = abs $ fromIntegral (modeRefresh mode) - fromIntegral (modeCRefresh cfg)
            confAspect :: Ratio Word
            confAspect = modeCWidth cfg % modeCHeight cfg
            aspect :: OutputMode -> Ratio Word
            aspect mode = fromIntegral (modeWidth mode) % fromIntegral (modeHeight mode)
            sameAspect :: OutputMode -> Bool
            sameAspect = (==) confAspect . aspect
            resDist :: OutputMode -> Int -- We know it's the same ration, so be lazy here
            resDist mode = abs $ fromIntegral (modeWidth mode) - fromIntegral (modeCWidth cfg)

findMode
    :: MonadIO m
    => Ptr WlrOutput
    -> Word32
    -> Word32
    -> Maybe Word32
    -> m (Maybe (Ptr OutputMode))
findMode output width height refresh = liftIO $ do
    modes <- getModes output
    paired <- forM modes $ \x -> do
        marshalled <- peek x
        pure (marshalled, x)
    let candidates = filter (\(mode, _) -> modeWidth mode == width && modeHeight mode == height) paired

    let fun = case refresh of
            Nothing -> maximumBy (compare  `on` (modeRefresh . fst))
            Just val -> minimumBy (compare `on` (abs . (-) (fromIntegral val :: Int) . fromIntegral . modeRefresh . fst))

    pure $ case candidates of
        [] -> Nothing
        xs -> Just . snd . fun $ xs

configureOutput
    :: Ptr WlrOutputLayout
    -> Map Text OutputConfig
    -> Text
    -> Ptr WlrOutput
    -> Way a ()
configureOutput layout configs name output = liftIO $ do
    let conf = M.lookup name configs
        position = outPosition =<< conf
        confMode = outMode =<< conf
    case position of
        Nothing -> addOutputAuto layout output
        Just (C.Point x y) -> addOutput layout output x y
    mode <- pickMode output confMode

    whenJust mode (`setOutputMode` output)

    whenJust (outScale =<< conf) (setOutputScale output)

newtype OutputAddEvent = OutputAdd Output
    deriving (Eq, Show)

instance EventClass OutputAddEvent

handleOutputAdd
    :: WSTag a
    => IORef Compositor
    -> [a]
    -> Ptr WlrOutput
    -> Way a FrameHandler
handleOutputAdd ref _ output = do
    comp <- liftIO $ readIORef ref
    state <- getState
    name <- liftIO $ getOutputName output

    configureOutput (compLayout comp) (configOutputs $ wayConfig state) name output

    current <- wayBindingOutputs <$> getState
    let out = Output output name
    liftIO $ modifyIORef current (out :)

    scale <- liftIO $ getOutputScale output
    seats <- getSeats
    liftIO $ forM_ seats $ \seat -> seatLoadScale seat scale

    sendEvent $ OutputAdd out
    makeCallback2 frameHandler


handleOutputRemove
    :: Ptr WlrOutput
    -> Way a ()
handleOutputRemove output = do
    state <- getState
    name <- liftIO $ getOutputName output
    let val = Output output name
    liftIO $ do
        modifyIORef (wayBindingMapping state) $  filter ((/=) val . snd)
        modifyIORef (wayBindingOutputs state) $  \xs -> xs \\ [val]

        T.hPutStr stderr "Detached output: "
        T.hPutStr stderr name
        T.hPutStrLn stderr "."

getOutputId :: Output -> Int
getOutputId = ptrToInt . outputRoots

outputFromWlr :: Ptr WlrOutput -> Way a Output
outputFromWlr ptr = do
    outs <- liftIO . readIORef . wayBindingOutputs =<< getState
    pure . fromJust . find ((==) ptr . outputRoots) $ outs

setOutputDirty :: MonadIO m => Output -> m ()
setOutputDirty out = liftIO $ setOutputNeedsSwap (outputRoots out) True
