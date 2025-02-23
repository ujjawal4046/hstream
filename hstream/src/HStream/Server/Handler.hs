{-# LANGUAGE BlockArguments      #-}
{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE OverloadedLists     #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}

module HStream.Server.Handler
  ( handlers
  )
where

import           Network.GRPC.HighLevel.Generated

import           HStream.Server.Handler.Admin
import           HStream.Server.Handler.Cluster
import           HStream.Server.Handler.Connector
import           HStream.Server.Handler.Query
import qualified HStream.Server.Handler.Stats        as H
import           HStream.Server.Handler.StoreAdmin
import           HStream.Server.Handler.Stream
import           HStream.Server.Handler.Subscription
import           HStream.Server.Handler.View
import           HStream.Server.HStreamApi
import           HStream.Server.Types

--------------------------------------------------------------------------------

handlers
  :: ServerContext
  -> IO (HStreamApi ServerRequest ServerResponse)
handlers serverContext@ServerContext{..} =
  return
    HStreamApi
      { hstreamApiEcho = echoHandler,
        -- Streams
        hstreamApiCreateStream = createStreamHandler serverContext,
        hstreamApiDeleteStream = deleteStreamHandler serverContext,
        hstreamApiListStreams = listStreamsHandler serverContext,
        hstreamApiAppend = appendHandler serverContext,
        -- Subscribe
        hstreamApiCreateSubscription = createSubscriptionHandler serverContext,
        hstreamApiDeleteSubscription = deleteSubscriptionHandler serverContext,
        hstreamApiListSubscriptions = listSubscriptionsHandler serverContext,
        hstreamApiCheckSubscriptionExist = checkSubscriptionExistHandler serverContext,

        hstreamApiStreamingFetch = streamingFetchHandler serverContext,

        -- Shards
        hstreamApiListShards = listShardsHandler serverContext,
        -- Reader
        hstreamApiCreateShardReader = createShardReaderHandler serverContext,
        hstreamApiDeleteShardReader = deleteShardReaderHandler serverContext,
        hstreamApiReadShard         = readShardHandler serverContext,

        -- Stats
        hstreamApiPerStreamTimeSeriesStats = H.perStreamTimeSeriesStats scStatsHolder,
        hstreamApiPerStreamTimeSeriesStatsAll = H.perStreamTimeSeriesStatsAll scStatsHolder,

        -- Query
        hstreamApiTerminateQueries = terminateQueriesHandler serverContext,
        hstreamApiExecuteQuery = executeQueryHandler serverContext,
        hstreamApiExecutePushQuery = executePushQueryHandler serverContext,
        -- FIXME:
        hstreamApiGetQuery = getQueryHandler serverContext,
        hstreamApiCreateQuery = createQueryHandler serverContext,
        hstreamApiListQueries = listQueriesHandler serverContext,
        hstreamApiDeleteQuery = deleteQueryHandler serverContext,
        hstreamApiRestartQuery = restartQueryHandler serverContext,

        -- Connector
        hstreamApiCreateConnector = createConnectorHandler serverContext,
        hstreamApiGetConnector = getConnectorHandler serverContext,
        hstreamApiListConnectors = listConnectorsHandler serverContext,
        hstreamApiDeleteConnector = deleteConnectorHandler serverContext,
        hstreamApiPauseConnector = pauseConnectorHandler serverContext,
        hstreamApiResumeConnector = resumeConnectorHandler serverContext,

        -- View
        hstreamApiGetView = getViewHandler serverContext,
        hstreamApiListViews = listViewsHandler serverContext,
        hstreamApiDeleteView = deleteViewHandler serverContext,

        hstreamApiGetNode = getStoreNodeHandler serverContext,
        hstreamApiListNodes = listStoreNodesHandler serverContext,

        -- Cluster
        hstreamApiDescribeCluster    = describeClusterHandler serverContext,
        hstreamApiLookupShard        = lookupShardHandler serverContext,
        hstreamApiLookupSubscription = lookupSubscriptionHandler serverContext,
        hstreamApiLookupShardReader  = lookupShardReaderHandler serverContext,
        hstreamApiLookupConnector    = lookupConnectorHandler serverContext,

        -- Admin
        hstreamApiSendAdminCommand = adminCommandHandler serverContext
      }

-------------------------------------------------------------------------------

echoHandler ::
  ServerRequest 'Normal EchoRequest EchoResponse ->
  IO (ServerResponse 'Normal EchoResponse)
echoHandler (ServerNormalRequest _metadata EchoRequest {..}) = do
  return $ ServerNormalResponse (Just $ EchoResponse echoRequestMsg) [] StatusOk ""
