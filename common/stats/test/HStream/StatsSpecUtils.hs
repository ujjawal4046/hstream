module HStream.StatsSpecUtils where

import           Control.Concurrent (threadDelay)
import           Data.Int           (Int64)
import qualified Data.Map.Strict    as Map
import           Data.Maybe         (fromJust)
import           Test.Hspec
import           Z.Data.CBytes      (CBytes)

import           HStream.Stats      (StatsHolder, resetStatsHolder)

{-# ANN module ("HLint: ignore Use head" :: String) #-}

mkTimeSeriesTest
  :: StatsHolder
  -> [Int]
  -> CBytes
  -> (StatsHolder -> CBytes -> Int64 -> IO ())
  -> (StatsHolder -> CBytes -> CBytes -> [Int] -> IO (Maybe [Double]))
  -> (StatsHolder -> CBytes -> [Int] -> IO (Either String (Map.Map CBytes [Double])))
  -> Expectation
mkTimeSeriesTest h intervals stats_name stats_add stats_get stats_getall = do
  stats_add h "key_1" 1000
  stats_add h "key_2" 10000
  -- NOTE: we choose to sleep 1s so that we can assume the speed of topic_1
  -- won't be faster than 2000B/s
  threadDelay 1000000
  stats_add h "key_1" 1000
  stats_add h "key_2" 10000

  stats_get h stats_name "non-existed-key" intervals
    `shouldReturn` Nothing

  Just [rate1_p5s, rate1_p10s] <- stats_get h stats_name "key_1" intervals
  rate1_p5s `shouldSatisfy` (\s -> s > 0 && s <= 2000)
  rate1_p10s `shouldSatisfy` (\s -> s > 0 && s <= 2000)
  Just [rate2_p5s, rate2_p10s] <- stats_get h stats_name "key_2" intervals
  rate2_p5s `shouldSatisfy` (\s -> s > 2000 && s <= 20000)
  rate2_p10s `shouldSatisfy` (\s -> s > 2000 && s <= 20000)

  Right m <- stats_getall h stats_name intervals
  Map.lookup "key_1" m `shouldSatisfy` ((\s -> s!!0 > 0 && s!!0 <= 2000) . fromJust)
  Map.lookup "key_2" m `shouldSatisfy` ((\s -> s!!1 > 2000 && s!!1 <= 20000) . fromJust)

  resetStatsHolder h
  stats_getall h stats_name intervals `shouldReturn` Right Map.empty
