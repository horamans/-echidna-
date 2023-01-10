{-# LANGUAGE TemplateHaskell #-}

module Echidna.UI where

import Brick
import Brick.BChan
import Control.Concurrent (killThread, threadDelay)
import Control.Lens
import Control.Monad (forever, void, when, replicateM )
import Control.Monad.Catch (MonadCatch(..))
import Control.Monad.IO.Class (MonadIO(..))
import Control.Monad.Reader (MonadReader, runReader)
import Control.Monad.Random (getRandom)
import Control.Monad.Random.Strict (MonadRandom)
import Data.ByteString.Lazy qualified as BS
import Data.Has (Has(..))
import Data.List (transpose)
import Data.Map.Strict qualified as H
import Data.Maybe (fromMaybe)
import Data.Set qualified as S
import Graphics.Vty (Config, Event(..), Key(..), Modifier(..), defaultConfig, inputMap, mkVty)
import System.Posix.Terminal (queryTerminal)
import System.Posix.Types (Fd(..))
import UnliftIO (MonadUnliftIO)
import UnliftIO.Concurrent (forkIO, getNumCapabilities)
import UnliftIO.IORef
import UnliftIO.MVar (tryTakeMVar, newEmptyMVar, putMVar)

import EVM (VM)
import EVM.Dapp (DappInfo)

import Echidna.ABI
import Echidna.Campaign (campaign)
import Echidna.Output.JSON qualified
import Echidna.Types.Solidity (SolConf(..))
import Echidna.Types.Campaign
import Echidna.Types.Test (TestConf(..), EchidnaTest, testState, TestState (Solved, Large, Open, Passed))
import Echidna.Types.Tx (Tx, TxConf)
import Echidna.Types.World (World)
import Echidna.UI.Report
import Echidna.UI.Widgets

data UIConf = UIConf { _maxTime       :: Maybe Int
                     , _operationMode :: OperationMode
                     }
data OperationMode = Interactive | NonInteractive OutputFormat deriving Show
data OutputFormat = Text | JSON | None deriving Show

instance Read OutputFormat where
  readsPrec _ = \case 't':'e':'x':'t':r -> [(Text, r)]
                      'j':'s':'o':'n':r -> [(JSON, r)]
                      'n':'o':'n':'e':r -> [(None, r)]
                      _ -> []

makeLenses ''UIConf

data CampaignEvent = CampaignUpdated Campaign | CampaignTimedout Campaign

-- TODO: sync corpus from time to time?
data WorkerSyncMessage
  = TestFalsified Int EchidnaTest -- TODO: rethink if whole test should be pushed
  | TestLimitReached Int
  | ShrinkLimitReached Int
  | TimeLimitReached -- timed out, exit

-- | Set up and run an Echidna 'Campaign' and display interactive UI or
-- print non-interactive output in desired format at the end
ui :: ( MonadCatch m, MonadRandom m, MonadReader x m, MonadUnliftIO m
      , Has SolConf x, Has TestConf x, Has TxConf x, Has CampaignConf x
      , Has Names x, Has UIConf x, Has DappInfo x)
   => VM             -- ^ Initial VM state
   -> World          -- ^ Initial world state
   -> [EchidnaTest]  -- ^ Tests to evaluate
   -> GenDict
   -> [[Tx]]
   -> m Campaign
ui vm w ts d txs = do
  uiConf <- view hasLens

  terminalPresent <- isTerminal
  let effectiveMode = case uiConf ^. operationMode of
        Interactive | not terminalPresent -> NonInteractive Text
        other -> other

  numCapabilities <- getNumCapabilities
  -- TODO: Performance peaks around 12 jobs, even if there are 24 CPU threads
  -- available (Ryzen 5900X). Is it possible to tweak scheduler/GC?
  let njobs = numCapabilities -- max 12 numCapabilities
  -- Communication channels with workers
  ioRefs <- replicateM njobs $ newIORef defaultCampaign
  mVars <- replicateM njobs newEmptyMVar

  let worker (ioRef, mVar) = forkIO $ void $ do
        -- Generate a new seed for each worker
        s <- getRandom
        campaign (syncWorker ioRef mVar ioRefs) vm w ts (Just $ d & defSeed .~ s) txs

      maybeTimeout = secToUsec <$> uiConf ^. maxTime
      secToUsec = (* 1000000)

  {-workerSyncer = forkIO $ void $ do
        campaigns <- sequence $ readIORef <$> ioRefs
        pure undefined-}

  case effectiveMode of
    Interactive -> do
      -- Channel to push events to update UI
      bc <- liftIO $ newBChan 100

      let updateUI e = do
            campaigns <- mapM readIORef ioRefs
            -- TODO: push MVar messages
            writeBChan bc $ e (mergeCampaigns campaigns)

      ticker <- liftIO $ forkIO $ -- run UI update every 100ms
        forever $ threadDelay 100000 >> updateUI CampaignUpdated

      -- Timeouter thread, sleep for the timeout then order all workers
      -- to exit and update the UI
      case maybeTimeout of
        Just t -> liftIO $ void $ forkIO $ do
          threadDelay t
          killThread ticker
          mapM_ (`putMVar` TimeLimitReached) mVars
          updateUI CampaignTimedout
        Nothing -> pure ()

      _threadIds <- mapM worker (zip ioRefs mVars)

      -- UI initialization
      let vty = mkVty vtyConfig
      initialVty <- liftIO vty
      app <- customMain initialVty vty (Just bc) <$> monitor
      liftIO $ void $ app (defaultCampaign, Uninitialized)

      mapM_ (`putMVar` TimeLimitReached) mVars

      campaigns <- mapM readIORef ioRefs
      let final = mergeCampaigns campaigns
      liftIO . putStrLn =<< ppCampaign final
      pure final

    NonInteractive outputFormat -> do
      -- Timeouter thread, sleep for the timeout then order all workers to exit
      -- TODO: this is similar to the UI one, think about extracting it?
      didTimeout <- newIORef False

      case maybeTimeout of
        Just t -> liftIO $ void $ forkIO $ do
          threadDelay t
          mapM_ (`putMVar` TimeLimitReached) mVars
          atomicWriteIORef didTimeout True
        Nothing -> pure ()

      _threadIds <- mapM worker (zip ioRefs mVars)

      -- TODO wait for threads
      liftIO $ threadDelay 1000000

      campaigns <- mapM readIORef ioRefs
      let final = mergeCampaigns campaigns

      case outputFormat of
        JSON ->
          liftIO . BS.putStr $ Echidna.Output.JSON.encodeCampaign final
        Text -> do
          liftIO . putStrLn =<< ppCampaign final
          timedout <- readIORef didTimeout
          when timedout $ liftIO $ putStrLn "TIMEOUT!"
        None ->
          pure ()
      pure final

  where
  syncWorker ioRef mVar ioRefs = do
    c <- use hasLens
    -- push campaign update
    liftIO $ atomicWriteIORef ioRef c
    -- read a message if a breakthrough happened in another worker
    -- TODO use a channel instead of MVar as it could be block the UI thread a bit
    maybeMessage <- liftIO $ tryTakeMVar mVar
    case maybeMessage of
      Nothing -> pure False
      Just message -> do
        let (c', stop) = updateCampaign c message
        put c'
        pure stop
    where
    updateCampaign c = \case
      TestFalsified i t ->
        -- NOTE: the first worker wins, here we overwrite work that was
        -- done by the current worker, TODO: rethink this
        (c & tests . ix i .~ t, False)
      TestLimitReached i ->
        -- bump the all? Open trials to max to stop fuzzing
        --case c ^. tests . at i of
        --  Nothing -> undefined
        --  Just t -> undefined
        error "implement me"
      ShrinkLimitReached i ->
        -- bump the all? Open trials to max to stop fuzzing
        error "implement me"
      TimeLimitReached -> (c, True)


-- Summarize all campaigns from workers as a single campaign
-- TODO: this should return a richer data structure, good enough for now
mergeCampaigns :: [Campaign] -> Campaign
mergeCampaigns [] = error "won't happen, fix me with NonEmpty"
mergeCampaigns [c] = c -- don't even try
mergeCampaigns campaigns =
  defaultCampaign
    & tests .~ (mergeTests <$> transpose (view tests <$> campaigns))
    & coverage .~ H.unionsWith S.union (view coverage <$> campaigns)
    & gasInfo .~ mempty -- TODO
    & genDict .~ defaultDict -- TODO
    & corpus .~ mempty -- TODO
    & ncallseqs .~ sum (view ncallseqs <$> campaigns)
  where
  mergeTests :: [EchidnaTest] -> EchidnaTest
  mergeTests [] = error "won't happen, fix me with NonEmpty"
  mergeTests (f:ts) =
    foldl (\t acc ->
      case (t ^. testState, acc ^. testState) of
        -- update if better what we have so far
        (Solved, _) -> t
        (Large i, Large j) -> t & testState .~ Large (i+j)
        (Large _, Open _) -> t
        (Large _, Passed) -> t -- shoudn't happen but just in case
        (Open i, Open j) -> t & testState .~ Open (i+j)
        -- skip otherwise
        _ -> acc
      ) f ts

vtyConfig :: Config
vtyConfig = defaultConfig { inputMap = (Nothing, "\ESC[6;2~", EvKey KPageDown [MShift]) :
                                       (Nothing, "\ESC[5;2~", EvKey KPageUp [MShift]) :
                                       inputMap defaultConfig
                          }

-- | Check if we should stop drawing (or updating) the dashboard, then do the right thing.
monitor :: (MonadReader x m, Has CampaignConf x, Has Names x, Has TxConf x)
        => m (App (Campaign, UIState) CampaignEvent ())
monitor = do
  let cs :: (CampaignConf, Names, TxConf) -> (Campaign, UIState) -> Widget ()
      cs s c = runReader (campaignStatus c) s

      se (AppEvent (CampaignUpdated c')) = put (c', Running)
      se (AppEvent (CampaignTimedout c')) = put (c', Timedout)
      se (VtyEvent (EvKey KEsc _))                         = halt
      se (VtyEvent (EvKey (KChar 'c') l)) | MCtrl `elem` l = halt
      se _                                                 = pure ()
  s <- (,,) <$> view hasLens <*> view hasLens <*> view hasLens
  pure $ App (pure . cs s) neverShowCursor se (pure ()) (const attrs)

-- | Heuristic check that we're in a sensible terminal (not a pipe)
isTerminal :: MonadIO m => m Bool
isTerminal = liftIO $ (&&) <$> queryTerminal (Fd 0) <*> queryTerminal (Fd 1)
