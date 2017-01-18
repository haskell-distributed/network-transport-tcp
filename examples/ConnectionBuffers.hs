{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE RankNTypes #-}

module ConnectionBuffers where

import Control.Monad (forM_, unless)
import Network.Transport
import qualified Network.Transport.TCP as TCP
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Control.Exception
import Control.Concurrent.Chan.Unagi.Bounded
import Control.Concurrent.MVar
import Data.Typeable

newConnectionBufferTCPEndPoint
  :: TCP.TransportInternals
  -> QDiscParams
  -> IO (Either (TransportError NewEndPointErrorCode) (TCP.TCPEndPoint EndPointEvent))
newConnectionBufferTCPEndPoint internals qdiscParams = do
  qdisc <- connectionBufferQDisc qdiscParams
  TCP.newEndPointInternal internals qdisc

data ConnectionEvent = Data ByteString | Closed | Lost

data EndPointEvent =
    PeerOpenedConnection !ConnectionId !Reliability !EndPointAddress !ConnectionBuffer
  | LocalEndPointClosed
  | LocalEndPointFailed
  | LocalTransportFailed

type EndPointBuffer = (InChan EndPointEvent, OutChan EndPointEvent)

newEndPointBuffer :: Int -> IO EndPointBuffer
newEndPointBuffer = newChan

type ConnectionBuffer = (InChan ConnectionEvent, OutChan ConnectionEvent)

newConnectionBuffer :: Int -> IO ConnectionBuffer
newConnectionBuffer = newChan

-- | State that will be held internally by a connection-buffer QDisc and
--   updated when events are enqueued.
data QDiscState = QDiscState {
    qdiscBuffers :: !(M.Map ConnectionId (EndPointAddress, ConnectionBuffer))
  , qdiscConnections :: !(M.Map EndPointAddress (S.Set ConnectionId))
  }

-- | Parameters for a connection-buffer QDisc.
data QDiscParams = QDiscParam {
    qdiscEventBufferSize :: Int
  , qdiscConnectionBufferSize :: Int
  , qdiscConnectionDataSize :: Int
  , qdiscInternalError :: forall t . InternalError -> IO t
  }

-- | A QDisc with a fixed bound for the size of the event queue and also for
--   the size of the buffers for each connection.
connectionBufferQDisc :: QDiscParams -> IO (TCP.QDisc EndPointEvent)
connectionBufferQDisc qdiscParams = do

  let endPointBound = qdiscEventBufferSize qdiscParams
  let connectionBound = qdiscConnectionBufferSize qdiscParams
  let maxChunkSize = qdiscConnectionDataSize qdiscParams
  let internalError = qdiscInternalError qdiscParams

  endPointBuffer <- newEndPointBuffer endPointBound
  let dequeue = readBuffer endPointBuffer

  qdiscState <- newMVar (QDiscState M.empty M.empty)


  let writeBufferRespectingChunkSize :: ConnectionBuffer -> ByteString -> IO ()
      writeBufferRespectingChunkSize cbuffer lbs = do
        let (now, later) = BS.splitAt maxChunkSize lbs
        writeBuffer cbuffer (Data now)
        unless (BS.null later) (writeBufferRespectingChunkSize cbuffer later)

  let enqueue event = case event of

        ConnectionOpened connid reliability addr -> do
          connectionBuffer <- newConnectionBuffer connectionBound
          modifyMVar qdiscState $ \st ->
            case M.lookup connid (qdiscBuffers st) of
              Nothing ->
                let alteration :: Maybe (S.Set ConnectionId) -> S.Set ConnectionId
                    alteration = maybe (S.singleton connid) (S.insert connid)
                    st' = st {
                        qdiscBuffers = M.insert connid (addr, connectionBuffer) (qdiscBuffers st)
                      , qdiscConnections = M.alter (Just . alteration) addr (qdiscConnections st)
                      }
                in  return (st', ())
              _ -> internalError DuplicateConnection
          let event = PeerOpenedConnection connid reliability addr connectionBuffer
          writeBuffer endPointBuffer event

        -- Events on a particular connection buffer will be consistent with
        -- their nt-tcp delivery because 'enqueue' will not be called
        -- concurrently for two events with the same 'ConnectionId'.
        --
        -- We're careful to hold the 'qdiscState' 'MVar' as little as possible,
        -- because this is shared by event producers for _all_ peers.

        ConnectionClosed connid -> do
          buffer <- modifyMVar qdiscState $ \st ->
            case M.lookup connid (qdiscBuffers st) of
              Nothing -> internalError UnknownConnectionClosed
              Just (addr, buffer) ->
                let updateIt set = if S.null set' then Nothing else Just set'
                      where
                      set' = S.delete connid set
                    st' = st {
                        qdiscBuffers = M.delete connid (qdiscBuffers st)
                      , qdiscConnections = M.update updateIt addr (qdiscConnections st)
                      }
                in  return (st', buffer)
          writeBuffer buffer Closed

        Received connid bytes -> do
          buffer <- withMVar qdiscState $ \st ->
            case M.lookup connid (qdiscBuffers st) of
              Nothing -> internalError UnknownConnectionReceived
              Just (_, buffer) -> return buffer
          -- Will block if the buffer is full, ultimately blocking the thread
          -- which is reading from the socket.
          writeBufferRespectingChunkSize buffer (BS.concat bytes)

        -- Ignore multicast.
        ReceivedMulticast _ _ -> return ()

        EndPointClosed ->
          let event = LocalEndPointClosed
          in  writeBuffer endPointBuffer event

        ErrorEvent (TransportError EventEndPointFailed _) ->
          let event = LocalEndPointFailed
          in  writeBuffer endPointBuffer event

        ErrorEvent (TransportError EventTransportFailed _) ->
          let event = LocalTransportFailed
          in  writeBuffer endPointBuffer event

        -- Must find all connections for that address and write 'Lost' to their
        -- buffers.
        ErrorEvent (TransportError (EventConnectionLost addr) _) -> do
          buffers <- modifyMVar qdiscState $ \st ->
            case M.lookup addr (qdiscConnections st) of
              Nothing -> internalError UnknownConnectionLost
              -- Get the buffers for all of the ConnectionIds and remove them
              -- from the state.
              -- connids is guaranteed non-empty set but GHC doesn't know that.
              Just connids ->
                let combine connid (buffers, deletedBuffers) =
                      case M.updateLookupWithKey (const (const Nothing)) connid buffers of
                        -- updateLookupWithKey returns the deleted value if it
                        -- was deleted.
                        (Just (_, buffer), buffers') -> (buffers', Just buffer : deletedBuffers)
                        _ -> (buffers, Nothing : deletedBuffers)
                    (buffers, deletedBuffers) = foldr combine (qdiscBuffers st, []) (S.toList connids)
                    st' = st {
                        qdiscBuffers = buffers
                      , qdiscConnections = M.delete addr (qdiscConnections st)
                      }
                in  return (st', deletedBuffers)
          forM_ buffers $ maybe (internalError InconsistentConnectionState) (flip writeBuffer Lost)

  return $ TCP.QDisc dequeue enqueue

writeBuffer :: (InChan t, OutChan t) -> t -> IO ()
writeBuffer = writeChan . fst

readBuffer :: (InChan t, OutChan t) -> IO t
readBuffer = readChan . snd

data InternalError =
    InconsistentConnectionState
  | UnknownConnectionClosed
  | UnknownConnectionLost
  | UnknownConnectionReceived
  | DuplicateConnection
  deriving (Typeable, Show)

instance Exception InternalError
