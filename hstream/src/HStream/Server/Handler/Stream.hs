{-# LANGUAGE BlockArguments      #-}
{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}

module HStream.Server.Handler.Stream
  ( -- * For grpc-haskell
    createStreamHandler
  , deleteStreamHandler
  , listStreamsHandler
  , listShardsHandler
  , appendHandler
  , createShardReaderHandler
  , deleteShardReaderHandler
  , readShardHandler
    -- * For hs-grpc-server
  , handleCreateStream
  , handleDeleteStream
  , handleListStreams
  , handleAppend
  , handleListShard
  , handleCreateShardReader
  , handleDeleteShardReader
  , handleReadShard
  ) where

import           Control.Exception
import qualified HsGrpc.Server                    as G
import qualified HsGrpc.Server.Types              as G
import           Network.GRPC.HighLevel.Generated

import qualified HStream.Exception                as HE
import qualified HStream.Logger                   as Log
import qualified HStream.Server.Core.Stream       as C
import           HStream.Server.Exception
import           HStream.Server.HStreamApi
import           HStream.Server.Types             (ServerContext (..))
import qualified HStream.Stats                    as Stats
import qualified HStream.Store                    as Store
import           HStream.ThirdParty.Protobuf      as PB
import           HStream.Utils

--------------------------------------------------------------------------------

createStreamHandler
  :: ServerContext
  -> ServerRequest 'Normal Stream Stream
  -> IO (ServerResponse 'Normal Stream)
createStreamHandler sc (ServerNormalRequest _metadata stream) = defaultExceptionHandle $ do
  Log.debug $ "Receive Create Stream Request: " <> Log.buildString' stream
  C.createStream sc stream
  returnResp stream

handleCreateStream :: ServerContext -> G.UnaryHandler Stream Stream
handleCreateStream sc _ stream = catchDefaultEx $
  C.createStream sc stream >> pure stream

-- DeleteStream have two mod: force delete or normal delete
-- For normal delete, if current stream have active subscription, the delete request will return error.
-- For force delete, if current stream have active subscription, the stream will be archived. After that,
-- old stream is no longer visible, current consumers can continue consume from the old subscription,
-- but new consumers are no longer allowed to join that subscription.
--
-- Note: For foce delete, delivery is only guaranteed as far as possible. Which means: a consumer which
-- terminates its consumption for any reason will have no chance to restart the consumption process.
deleteStreamHandler
  :: ServerContext
  -> ServerRequest 'Normal DeleteStreamRequest Empty
  -> IO (ServerResponse 'Normal Empty)
deleteStreamHandler sc (ServerNormalRequest _metadata request) = defaultExceptionHandle $ do
  Log.debug $ "Receive Delete Stream Request: " <> Log.buildString' request
  C.deleteStream sc request
  returnResp Empty

handleDeleteStream :: ServerContext -> G.UnaryHandler DeleteStreamRequest Empty
handleDeleteStream sc _ req = catchDefaultEx $
  C.deleteStream sc req >> pure Empty

listStreamsHandler
  :: ServerContext
  -> ServerRequest 'Normal ListStreamsRequest ListStreamsResponse
  -> IO (ServerResponse 'Normal ListStreamsResponse)
listStreamsHandler sc (ServerNormalRequest _metadata request) = defaultExceptionHandle $ do
  Log.debug "Receive List Stream Request"
  C.listStreams sc request >>= returnResp . ListStreamsResponse

handleListStreams :: ServerContext -> G.UnaryHandler ListStreamsRequest ListStreamsResponse
handleListStreams sc _ req = catchDefaultEx $
  ListStreamsResponse <$> C.listStreams sc req

appendHandler
  :: ServerContext
  -> ServerRequest 'Normal AppendRequest AppendResponse
  -> IO (ServerResponse 'Normal AppendResponse)
appendHandler sc@ServerContext{..} (ServerNormalRequest _metadata request@AppendRequest{..}) =
  appendStreamExceptionHandle inc_failed $ do
    returnResp =<< C.append sc request
  where
    inc_failed = do
      Stats.stream_stat_add_append_failed scStatsHolder cStreamName 1
      Stats.stream_time_series_add_append_failed_requests scStatsHolder cStreamName 1
    cStreamName = textToCBytes appendRequestStreamName

handleAppend :: ServerContext -> G.UnaryHandler AppendRequest AppendResponse
handleAppend sc@ServerContext{..} _ req = appendExHandle inc_failed $ C.append sc req
  where
    inc_failed = do
      Stats.stream_stat_add_append_failed scStatsHolder cStreamName 1
      Stats.stream_time_series_add_append_failed_requests scStatsHolder cStreamName 1
    cStreamName = textToCBytes (appendRequestStreamName req)
{-# INLINE handleAppend #-}

--------------------------------------------------------------------------------

listShardsHandler
  :: ServerContext
  -> ServerRequest 'Normal ListShardsRequest ListShardsResponse
  -> IO (ServerResponse 'Normal ListShardsResponse)
listShardsHandler sc (ServerNormalRequest _metadata request) = listShardsExceptionHandle $ do
  Log.debug "Receive List Shards Request"
  C.listShards sc request >>= returnResp . ListShardsResponse

handleListShard :: ServerContext -> G.UnaryHandler ListShardsRequest ListShardsResponse
handleListShard sc _ req = listShardsExHandle $
  ListShardsResponse <$> C.listShards sc req

createShardReaderHandler
  :: ServerContext
  -> ServerRequest 'Normal CreateShardReaderRequest CreateShardReaderResponse
  -> IO (ServerResponse 'Normal CreateShardReaderResponse)
createShardReaderHandler sc (ServerNormalRequest _metadata request) = defaultExceptionHandle $ do
  Log.debug $ "Receive Create ShardReader Request" <> Log.buildString' (show request)
  C.createShardReader sc request >>= returnResp

handleCreateShardReader
  :: ServerContext
  -> G.UnaryHandler CreateShardReaderRequest CreateShardReaderResponse
handleCreateShardReader sc _ req = catchDefaultEx $ C.createShardReader sc req

deleteShardReaderHandler
  :: ServerContext
  -> ServerRequest 'Normal DeleteShardReaderRequest Empty
  -> IO (ServerResponse 'Normal Empty)
deleteShardReaderHandler sc (ServerNormalRequest _metadata request) = defaultExceptionHandle $ do
  Log.debug $ "Receive Delete ShardReader Request" <> Log.buildString' (show request)
  C.deleteShardReader sc request >> returnResp Empty

handleDeleteShardReader
  :: ServerContext
  -> G.UnaryHandler DeleteShardReaderRequest Empty
handleDeleteShardReader sc _ req = catchDefaultEx $
  C.deleteShardReader sc req >> pure Empty

readShardHandler
  :: ServerContext
  -> ServerRequest 'Normal ReadShardRequest ReadShardResponse
  -> IO (ServerResponse 'Normal ReadShardResponse)
readShardHandler sc (ServerNormalRequest _metadata request) = defaultExceptionHandle $ do
  Log.debug $ "Receive read shard Request: " <> Log.buildString (show request)
  C.readShard sc request >>= returnResp . ReadShardResponse

handleReadShard
  :: ServerContext
  -> G.UnaryHandler ReadShardRequest ReadShardResponse
handleReadShard sc _ req = catchDefaultEx $ do
  ReadShardResponse <$> C.readShard sc req

--------------------------------------------------------------------------------
-- Exception Handlers

appendStreamExceptionHandle :: IO () -> HE.ExceptionHandle (ServerResponse 'Normal a)
appendStreamExceptionHandle f = HE.mkExceptionHandle' whileEx mkHandlers
  where
    whileEx :: forall e. Exception e => e -> IO ()
    whileEx err = Log.warning (Log.buildString' err) >> f
    handlers =
      [ Handler (\(err :: Store.NOTFOUND) ->
          return (StatusUnavailable, HE.mkStatusDetails err))
      , Handler (\(err :: Store.NOTINSERVERCONFIG) ->
          return (StatusUnavailable, HE.mkStatusDetails err))
      , Handler (\(err :: Store.NOSEQUENCER) -> do
          return (StatusUnavailable, HE.mkStatusDetails err))
      ] ++ defaultHandlers
    mkHandlers = HE.setRespType mkServerErrResp handlers

appendExHandle :: IO () -> (IO a -> IO a)
appendExHandle f = HE.mkExceptionHandle' whileEx handlers
  where
    whileEx :: forall e. Exception e => e -> IO ()
    whileEx err = Log.warning (Log.buildString' err) >> f
    handlers =
      [ Handler $ \(err :: Store.NOTFOUND) -> do
          G.throwGrpcError $ HE.mkGrpcStatus err G.StatusUnavailable
      , Handler $ \(err :: Store.NOTINSERVERCONFIG) ->
          G.throwGrpcError $ HE.mkGrpcStatus err G.StatusUnavailable
      , Handler $ \(err :: Store.NOSEQUENCER) -> do
          G.throwGrpcError $ HE.mkGrpcStatus err G.StatusUnavailable
      ] ++ defaultExHandlers

listShardsExceptionHandle :: HE.ExceptionHandle (ServerResponse 'Normal a)
listShardsExceptionHandle = HE.mkExceptionHandle . HE.setRespType mkServerErrResp $
   Handler (\(err :: Store.NOTFOUND) ->
          return (StatusUnavailable, HE.mkStatusDetails err))
  : defaultHandlers

listShardsExHandle :: IO a -> IO a
listShardsExHandle = HE.mkExceptionHandle handlers
  where
    handlers =
      [ Handler $ \(err :: Store.NOTFOUND) -> do
          G.throwGrpcError $ HE.mkGrpcStatus err G.StatusUnavailable
      ] ++ defaultExHandlers
