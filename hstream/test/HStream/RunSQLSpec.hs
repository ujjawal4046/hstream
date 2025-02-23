{-# LANGUAGE GADTs               #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE PatternSynonyms     #-}
{-# LANGUAGE ScopedTypeVariables #-}

module HStream.RunSQLSpec (spec) where

import           Control.Concurrent
import qualified Data.Aeson           as Aeson
import qualified Data.List            as L
import qualified Data.Text            as T
import           Test.Hspec

import           HStream.Logger       as Log
import           HStream.SpecUtils
import           HStream.Store.Logger (pattern C_DBG_ERROR,
                                       setLogDeviceDbgLevel)
import           HStream.Utils        hiding (newRandomText)

spec :: Spec
spec = describe "HStream.RunSQLSpec" $ do
  runIO setupSigsegvHandler
  runIO $ setLogDeviceDbgLevel C_DBG_ERROR

  baseSpec
  viewSpec

-------------------------------------------------------------------------------
-- BaseSpec

baseSpecAround :: ActionWith (HStreamClientApi, T.Text) -> HStreamClientApi -> IO ()
baseSpecAround = provideRunTest setup clean
  where
    setup api = do
      source <- newRandomText 20
      runCreateStreamSql api $ "CREATE STREAM " <> source <> " WITH (REPLICATE = 3);"
      return source
    clean api source =
      runDropSql api $ "DROP STREAM " <> source <> " IF EXISTS;"

baseSpec :: Spec
baseSpec = aroundAll provideHstreamApi $ aroundWith baseSpecAround $
  describe "SQL.BaseSpec" $ parallel $ do

  it "insert data and select" $ \(api, source) -> do
    _ <- forkIO $ do
      -- FIXME: requires a notification mechanism to ensure that the task
      -- starts successfully before inserting data
      threadDelay 5000000
      Log.d $ "Insert into " <> Log.buildText source <> " ..."
      runInsertSql api ("INSERT INTO " <> source <> " (temperature, humidity) VALUES (22, 80);")
      runInsertSql api ("INSERT INTO " <> source <> " (temperature, humidity) VALUES (15, 10);")

    -- TODO
    executeCommandPushQuery ("SELECT * FROM " <> source <> " EMIT CHANGES;")
      `shouldReturn` [ mkStruct [("temperature", Aeson.Number 22), ("humidity", Aeson.Number 80)]
                     , mkStruct [("temperature", Aeson.Number 15), ("humidity", Aeson.Number 10)]
                     ]

  it "GROUP BY without timewindow" $ \(api, source) -> do
    _ <- forkIO $ do
      -- FIXME: requires a notification mechanism to ensure that the task
      -- starts successfully before inserting data
      threadDelay 5000000
      Log.d $ "Insert into " <> Log.buildText source <> " ..."
      runInsertSql api ("INSERT INTO " <> source <> " (a, b) VALUES (1, 2);")
      runInsertSql api ("INSERT INTO " <> source <> " (a, b) VALUES (2, 2);")
      runInsertSql api ("INSERT INTO " <> source <> " (a, b) VALUES (3, 2);")
      runInsertSql api ("INSERT INTO " <> source <> " (a, b) VALUES (4, 3);")

    -- TODO
    executeCommandPushQuery ("SELECT SUM(a) AS result FROM " <> source <> " GROUP BY b EMIT CHANGES;")
      >>= (`shouldSatisfy`
            (\l -> not (L.null l) &&
                   L.last l == (mkStruct [("result", Aeson.Number 4)]) &&
                   L.init l `L.isSubsequenceOf` [ mkStruct [("result", Aeson.Number 1)]
                                              , mkStruct [("result", Aeson.Number 3)]
                                              , mkStruct [("result", Aeson.Number 6)]
                                              ]
            )
          )

-------------------------------------------------------------------------------
-- ViewSpec

viewSpecAround
  :: ActionWith (HStreamClientApi, (T.Text, T.Text, T.Text))
  -> HStreamClientApi -> IO ()
viewSpecAround = provideRunTest setup clean
  where
    setup api = do
      source1  <- ("runsql_view_source1_" <>) <$> newRandomText 20
      source2  <- ("runsql_view_source2_" <>) <$> newRandomText 20
      viewName <- ("runsql_view_view_"   <>)  <$> newRandomText 20
      runCreateStreamSql     api $ "CREATE STREAM " <> source1 <> ";"
      runCreateWithSelectSql api $ "CREATE STREAM " <> source2
                                <> " AS SELECT a, 1 AS b FROM " <> source1
                                <> " EMIT CHANGES;"
      runQuerySimple_ api $ "CREATE VIEW " <> viewName
                         <> " AS SELECT SUM(a), b FROM " <> source2
                         <> " GROUP BY b EMIT CHANGES;"
      -- FIXME: wait the SELECT task to be initialized.
      threadDelay 5000000
      return (source1, source2, viewName)
    clean api (source1, source2, viewName) = do
      runDropSql api $ "DROP VIEW " <> viewName <> " IF EXISTS;"
      runDropSql api $ "DROP STREAM " <> source2 <> " IF EXISTS;"
      runDropSql api $ "DROP STREAM " <> source1 <> " IF EXISTS;"

viewSpec :: Spec
viewSpec =
  aroundAll provideHstreamApi $ aroundAllWith viewSpecAround $
  describe "SQL.ViewSpec" $ parallel $ do

{-
-- FIXME: the mechanism to distinguish streams and views is broken by new HStore connector

  it "show streams should not include views" $ \(api, (_s1, _s2, view)) -> do
    res <- runShowStreamsSql api "SHOW STREAMS;"
    L.sort (words res)
      `shouldNotContain` map T.unpack (L.sort [view])

  it "show views should not include streams" $ \(api, (s1, s2, _view)) -> do
    res <- runShowViewsSql api "SHOW VIEWS;"
    L.sort (words res)
      `shouldNotContain` map T.unpack (L.sort [s1, s2])
-}

  it "select from view" $ \(api, (source1, _source2, viewName)) -> do
    runInsertSql api $ "INSERT INTO " <> source1 <> " (a) VALUES (1);"
    runInsertSql api $ "INSERT INTO " <> source1 <> " (a) VALUES (2);"
    threadDelay 4000000
    runQuerySimple api ("SELECT * FROM " <> viewName <> " WHERE b = 1;")
      `grpcShouldReturn` mkViewResponse (mkStruct [ ("SUM(a)", Aeson.Number 3)
                                                  , ("b", Aeson.Number 1)
                                                  ])

    runInsertSql api $ "INSERT INTO " <> source1 <> " (a) VALUES (3);"
    runInsertSql api $ "INSERT INTO " <> source1 <> " (a) VALUES (4);"
    threadDelay 4000000
    runQuerySimple api ("SELECT * FROM " <> viewName <> " WHERE b = 1;")
      `grpcShouldReturn` mkViewResponse (mkStruct [ ("SUM(a)", Aeson.Number 10)
                                                  , ("b", Aeson.Number 1)
                                                  ])
