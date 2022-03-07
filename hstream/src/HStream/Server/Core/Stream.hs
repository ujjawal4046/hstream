{-# LANGUAGE DataKinds       #-}
{-# LANGUAGE OverloadedLists #-}

module HStream.Server.Core.Stream
  ( createStream
  , deleteStream
  , listStreams
  , appendStream
  ) where

import           Control.Exception                (catch, throwIO)
import           Control.Monad                    (unless, void, when)
import qualified Data.ByteString                  as BS
import           Data.Maybe                       (isJust)
import           Data.Text                        (Text)
import qualified Data.Text                        as Text
import qualified Data.Vector                      as V
import           GHC.Stack                        (HasCallStack)
import           Network.GRPC.HighLevel.Generated
import           Z.Data.CBytes                    (CBytes)
import           ZooKeeper                        (zooExists, zooMulti)
import           ZooKeeper.Exception              (ZNODEEXISTS)
import           ZooKeeper.Types                  (ZHandle)

import           HStream.Connector.HStore         (transToStreamName)
import qualified HStream.Logger                   as Log
import           HStream.Server.Core.Common       (deleteStoreStream)
import           HStream.Server.Exception         (FoundActiveSubscription (..),
                                                   StreamExists (..),
                                                   StreamNotExist (..))
import qualified HStream.Server.HStreamApi        as API
import           HStream.Server.Handler.Common    (checkIfSubsOfStreamActive,
                                                   removeStreamRelatedPath)
import           HStream.Server.Persistence       (streamRootPath)
import qualified HStream.Server.Persistence       as P
import           HStream.Server.Types             (ServerContext (..))
import qualified HStream.Stats                    as Stats
import qualified HStream.Store                    as S
import           HStream.ThirdParty.Protobuf      as PB
import           HStream.Utils

-------------------------------------------------------------------------------

-- createStream will create a stream with a default partition
-- FIXME: Currently, creating a stream which partially exists will do the job
-- but return failure response
createStream :: HasCallStack => ServerContext -> API.Stream -> IO (ServerResponse 'Normal API.Stream)
createStream ServerContext{..} stream@API.Stream{..} = do
  let nameCB   = textToCBytes streamStreamName
      streamId = transToStreamName streamStreamName
      repFac   = fromIntegral streamReplicationFactor
  zNodesExist <- catch (createStreamRelatedPath zkHandle nameCB >> return False)
                       (\(_::ZNODEEXISTS) -> return True)
  storeExists <- catch (S.createStream scLDClient streamId (S.LogAttrs $ S.HsLogAttrs repFac mempty)
                        >> return False)
                       (\(_ :: S.EXISTS) -> return True)
  when (storeExists || zNodesExist) $ do
    Log.warning $ "Stream exists in" <> (if zNodesExist then " <zk path>" else "") <> (if storeExists then " <hstore>." else ".")
    throwIO $ StreamExists zNodesExist storeExists
  returnResp stream

deleteStream :: ServerContext
             -> API.DeleteStreamRequest
             -> IO (ServerResponse 'Normal Empty)
deleteStream sc@ServerContext{..} API.DeleteStreamRequest{..} = do
  zNodeExists <- isJust <$> zooExists zkHandle (streamRootPath <> "/" <> nameCB)
  storeExists <- S.doesStreamExist scLDClient streamId
  case (zNodeExists, storeExists) of
    -- Normal path
    (True, True) -> normalDelete
    -- Deletion of a stream was incomplete, failed to clear zk path,
    -- we will get here when client retry the delete request
    (True, False) -> cleanZkNode
    -- Abnormal Path: Since we always delete stream before clear zk path, get here may
    -- means some unexpected error. Since it is a delete request and we just want to destroy the resource,
    -- so it should be fine to just delete the stream instead of throw an exception
    (False, True) -> storeDelete
    -- Concurrency problem, or we finished delete request but client lose the
    -- response and retry
    (False, False) -> unless deleteStreamRequestIgnoreNonExist $ throwIO StreamNotExist
  returnResp Empty
  where
    normalDelete = do
      isActive <- checkIfActive
      if isActive
        then do
          unless deleteStreamRequestForce $ throwIO FoundActiveSubscription
          S.archiveStream scLDClient streamId
        else storeDelete
      cleanZkNode
    storeDelete  = void $ deleteStoreStream sc streamId deleteStreamRequestIgnoreNonExist

    streamId      = transToStreamName deleteStreamRequestStreamName
    nameCB        = textToCBytes deleteStreamRequestStreamName
    checkIfActive = checkIfSubsOfStreamActive zkHandle nameCB
    cleanZkNode   = removeStreamRelatedPath zkHandle nameCB

listStreams
  :: HasCallStack
  => ServerContext
  -> API.ListStreamsRequest
  -> IO (V.Vector API.Stream)
listStreams ServerContext{..} API.ListStreamsRequest = do
  streams <- S.findStreams scLDClient S.StreamTypeStream
  V.forM (V.fromList streams) $ \stream -> do
    r <- S.getStreamReplicaFactor scLDClient stream
    return $ API.Stream (Text.pack . S.showStreamName $ stream) (fromIntegral r)

appendStream :: ServerContext -> API.AppendRequest -> Maybe Text -> IO API.AppendResponse
appendStream ServerContext{..} API.AppendRequest{..} partitionKey = do
  timestamp <- getProtoTimestamp
  let payloads = encodeRecord . updateRecordTimestamp timestamp <$> appendRequestRecords
      payloadSize = V.sum $ BS.length . API.hstreamRecordPayload <$> appendRequestRecords
      streamName = textToCBytes appendRequestStreamName
      streamID = S.mkStreamId S.StreamTypeStream streamName
      key = textToCBytes <$> partitionKey
  -- XXX: Should we add a server option to toggle Stats?
  Stats.stream_time_series_add_append_in_bytes scStatsHolder streamName (fromIntegral payloadSize)

  logId <- S.getUnderlyingLogId scLDClient streamID key
  S.AppendCompletion {..} <- S.appendBatchBS scLDClient logId (V.toList payloads) cmpStrategy Nothing
  let records = V.zipWith (\_ idx -> API.RecordId appendCompLSN idx) appendRequestRecords [0..]
  return $ API.AppendResponse appendRequestStreamName records

--------------------------------------------------------------------------------

createStreamRelatedPath :: ZHandle -> CBytes -> IO ()
createStreamRelatedPath zk streamName = do
  -- rootPath/streams/{streamName}
  -- rootPath/streams/{streamName}/keys
  -- rootPath/streams/{streamName}/subscriptions
  -- rootPath/lock/streams/{streamName}
  -- rootPath/lock/streams/{streamName}/subscriptions
  let streamPath = P.streamRootPath <> "/" <> streamName
      keyPath    = P.mkPartitionKeysPath streamName
      subPath    = P.mkStreamSubsPath streamName
      lockPath   = P.streamLockPath <> "/" <> streamName
      streamSubLockPath = P.mkStreamSubsLockPath streamName
  void $ zooMulti zk $ P.createPathOp <$> [streamPath, keyPath, subPath, lockPath, streamSubLockPath]
