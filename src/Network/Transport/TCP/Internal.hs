-- | Utility functions for TCP sockets
module Network.Transport.TCP.Internal
  ( ControlHeader(..)
  , encodeControlHeader
  , decodeControlHeader
  , ConnectionRequestResponse(..)
  , encodeConnectionRequestResponse
  , decodeConnectionRequestResponse
  , forkServer
  , recvWithLength
  , recvExact
  , recvWord32
  , encodeWord32
  , tryCloseSocket
  , tryShutdownSocketBoth
  , decodeSockAddr
  , EndPointId
  , TCPInternalSettings(..)
  , defaultTCPInternalSettings
  , encodeEndPointAddress
  , decodeEndPointAddress
  ) where

#if ! MIN_VERSION_base(4,6,0)
import Prelude hiding (catch)
#endif

import Network.Transport.Internal
  ( decodeWord32
  , encodeWord32
  , void
  , tryIO
  , forkIOWithUnmask
  )

import Network.Transport ( EndPointAddress(..) )

#ifdef USE_MOCK_NETWORK
import qualified Network.Transport.TCP.Mock.Socket as N
#else
import qualified Network.Socket as N
#endif
  ( HostName
  , ServiceName
  , Socket
  , SocketType(Stream)
  , SocketOption(ReuseAddr, CustomSockOpt)
  , getAddrInfo
  , defaultHints
  , socket
  , bindSocket
  , listen
  , addrFamily
  , addrAddress
  , defaultProtocol
  , setSocketOption
  , accept
  , sClose
  , socketPort
  , shutdown
  , ShutdownCmd(ShutdownBoth)
  , SockAddr(..)
  , inet_ntoa
  )

#ifdef USE_MOCK_NETWORK
import qualified Network.Transport.TCP.Mock.Socket.ByteString as NBS (recv)
#else
import qualified Network.Socket.ByteString as NBS (recv)
#endif

import Data.Word (Word32)

import Control.Monad (forever, when)
import Control.Exception (SomeException, catch, bracketOnError, throwIO, mask_)
import Control.Concurrent (ThreadId, forkIO)
import Control.Concurrent.MVar
  ( MVar
  , newEmptyMVar
  , putMVar
  , readMVar
  )
import Control.Monad (forever, when)
import Control.Exception
  ( SomeException
  , catch
  , bracketOnError
  , throwIO
  , mask_
  , mask
  , finally
  , onException
  )

import Control.Applicative ((<$>), (<*>))
import Data.Word (Word32)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS (length, concat, null)
import Data.ByteString.Lazy.Internal (smallChunkSize)
import qualified Data.ByteString.Char8 as BSC (unpack, pack)

-- | Local identifier for an endpoint within this transport
type EndPointId = Word32

-- | Parameters that have to be passed to every socket function
-- because they cannot be set on the socket permanently.
data TCPInternalSettings = TCPInternalSettings {
    -- | Whether to set TCP_QUICKACK after every `recv` and to what.
    --
    -- See the `tcpForceQuickAck` setting in "Network.Transport.TCP"
    -- for which OSs this setting works on.
    tcpInternalForceQuickAck :: Maybe Bool
  }

-- | Default internal TCP parameters.
defaultTCPInternalSettings = TCPInternalSettings {
    tcpInternalForceQuickAck = Nothing
  }

-- | Control headers
data ControlHeader =
    -- | Tell the remote endpoint that we created a new connection
    CreatedNewConnection
    -- | Tell the remote endpoint we will no longer be using a connection
  | CloseConnection
    -- | Request to close the connection (see module description)
  | CloseSocket
    -- | Sent by an endpoint when it is closed.
  | CloseEndPoint
    -- | Message sent to probe a socket
  | ProbeSocket
    -- | Acknowledgement of the ProbeSocket message
  | ProbeSocketAck
  deriving (Show)

decodeControlHeader :: Word32 -> Maybe ControlHeader
decodeControlHeader w32 = case w32 of
  0 -> Just CreatedNewConnection
  1 -> Just CloseConnection
  2 -> Just CloseSocket
  3 -> Just CloseEndPoint
  4 -> Just ProbeSocket
  5 -> Just ProbeSocketAck
  _ -> Nothing

encodeControlHeader :: ControlHeader -> Word32
encodeControlHeader ch = case ch of
  CreatedNewConnection -> 0
  CloseConnection      -> 1
  CloseSocket          -> 2
  CloseEndPoint        -> 3
  ProbeSocket          -> 4
  ProbeSocketAck       -> 5

-- | Response sent by /B/ to /A/ when /A/ tries to connect
data ConnectionRequestResponse =
    -- | /B/ accepts the connection
    ConnectionRequestAccepted
    -- | /A/ requested an invalid endpoint
  | ConnectionRequestInvalid
    -- | /A/s request crossed with a request from /B/ (see protocols)
  | ConnectionRequestCrossed
    -- | /A/ gave an incorrect host (did not match the host that /B/ observed).
  | ConnectionRequestHostMismatch
  deriving (Show)

decodeConnectionRequestResponse :: Word32 -> Maybe ConnectionRequestResponse
decodeConnectionRequestResponse w32 = case w32 of
  0 -> Just ConnectionRequestAccepted
  1 -> Just ConnectionRequestInvalid
  2 -> Just ConnectionRequestCrossed
  3 -> Just ConnectionRequestHostMismatch
  _ -> Nothing

encodeConnectionRequestResponse :: ConnectionRequestResponse -> Word32
encodeConnectionRequestResponse crr = case crr of
  ConnectionRequestAccepted     -> 0
  ConnectionRequestInvalid      -> 1
  ConnectionRequestCrossed      -> 2
  ConnectionRequestHostMismatch -> 3

-- | Start a server at the specified address.
--
-- This sets up a server socket for the specified host and port. Exceptions
-- thrown during setup are not caught.
--
-- Once the socket is created we spawn a new thread which repeatedly accepts
-- incoming connections and executes the given request handler in another
-- thread. If any exception occurs the accepting thread terminates and calls
-- the terminationHandler. Threads spawned for previous accepted connections
-- are not killed.
-- This exception may occur because of a call to 'N.accept', or because the
-- thread was explicitly killed.
--
-- The request handler is not responsible for closing the socket. It will be
-- closed once that handler returns. Take care to ensure that the socket is not
-- used after the handler returns, or you will get undefined behavior
-- (the file descriptor may be re-used).
--
-- The return value includes the port was bound to. This is not always the same
-- port as that given in the argument. For example, binding to port 0 actually
-- binds to a random port, selected by the OS.
forkServer :: N.HostName                     -- ^ Host
           -> N.ServiceName                  -- ^ Port
           -> Int                            -- ^ Backlog (maximum number of queued connections)
           -> Bool                           -- ^ Set ReuseAddr option?
           -> (SomeException -> IO ())       -- ^ Error handler. Called with an
                                             --   exception raised when
                                             --   accepting a connection.
           -> (SomeException -> IO ())       -- ^ Termination handler. Called
                                             --   when the error handler throws
                                             --   an exception.
           -> (IO () -> (N.Socket, N.SockAddr) -> IO ())
                                             -- ^ Request handler. Gets an
                                             --   action which completes when
                                             --   the socket is closed.
           -> IO (N.ServiceName, ThreadId)
forkServer host port backlog reuseAddr errorHandler terminationHandler requestHandler = do
    -- Resolve the specified address. By specification, getAddrInfo will never
    -- return an empty list (but will throw an exception instead) and will return
    -- the "best" address first, whatever that means
    addr:_ <- N.getAddrInfo (Just N.defaultHints) (Just host) (Just port)
    bracketOnError (N.socket (N.addrFamily addr) N.Stream N.defaultProtocol)
                   tryCloseSocket $ \sock -> do
      when reuseAddr $ N.setSocketOption sock N.ReuseAddr 1
      N.bindSocket sock (N.addrAddress addr)
      N.listen sock backlog

      -- Close up and fill the synchonizing MVar.
      let release :: ((N.Socket, N.SockAddr), MVar ()) -> IO ()
          release ((sock, _), socketClosed) =
            N.sClose sock `finally` putMVar socketClosed ()

      -- Run the request handler.
      let act restore (sock, sockAddr) = do
            socketClosed <- newEmptyMVar
            void $ forkIO $ restore $ do
              requestHandler (readMVar socketClosed) (sock, sockAddr)
              `finally`
              release ((sock, sockAddr), socketClosed)

      let acceptRequest :: IO ()
          acceptRequest = mask $ \restore -> do
            -- Async exceptions are masked so that, if accept does give a
            -- socket, we'll always deliver it to the handler before the
            -- exception is raised.
            -- If it's a Right handler then it will eventually be closed.
            -- If it's a Left handler then we assume the handler itself will
            -- close it.
            (sock, sockAddr) <- N.accept sock
            -- Looks like 'act' will never throw an exception, but to be
            -- safe we'll close the socket if it does.
            let handler :: SomeException -> IO ()
                handler _ = N.sClose sock
            catch (act restore (sock, sockAddr)) handler

      -- We start listening for incoming requests in a separate thread. When
      -- that thread is killed, we close the server socket and the termination
      -- handler is run. We have to make sure that the exception handler is
      -- installed /before/ any asynchronous exception occurs. So we mask_, then
      -- fork (the child thread inherits the masked state from the parent), then
      -- unmask only inside the catch.
      (,) <$> fmap show (N.socketPort sock) <*>
        (mask_ $ forkIOWithUnmask $ \unmask ->
          catch (unmask (forever (catch acceptRequest errorHandler))) $ \ex -> do
            tryCloseSocket sock
            terminationHandler ex)

-- | Read a length and then a payload of that length, subject to a limit
--   on the length.
--   If the length (first 'Word32' received) is greater than the limit then
--   an exception is thrown.
recvWithLength :: TCPInternalSettings -> Word32 -> N.Socket -> IO [ByteString]
recvWithLength settings limit sock = do
  len <- recvWord32 settings sock
  when (len > limit) $
    throwIO (userError "recvWithLength: limit exceeded")
  recvExact settings sock len

-- | Receive a 32-bit unsigned integer
recvWord32 :: TCPInternalSettings -> N.Socket -> IO Word32
recvWord32 settings = fmap (decodeWord32 . BS.concat) . flip (recvExact settings) 4

-- | Close a socket, ignoring I/O exceptions.
tryCloseSocket :: N.Socket -> IO ()
tryCloseSocket sock = void . tryIO $
  N.sClose sock

-- | Shutdown socket sends and receives, ignoring I/O exceptions.
tryShutdownSocketBoth :: N.Socket -> IO ()
tryShutdownSocketBoth sock = void . tryIO $
  N.shutdown sock N.ShutdownBoth

-- | Read an exact number of bytes from a socket
--
-- Throws an I/O exception if the socket closes before the specified
-- number of bytes could be read
recvExact :: TCPInternalSettings -- ^ Settings for specific TCP behaviour
          -> N.Socket        -- ^ Socket to read from
          -> Word32          -- ^ Number of bytes to read
          -> IO [ByteString] -- ^ Data read
recvExact settings sock len = go [] len
  where
    go :: [ByteString] -> Word32 -> IO [ByteString]
    go acc 0 = return (reverse acc)
    go acc l = do
      bs <- NBS.recv sock (fromIntegral l `min` smallChunkSize)
      -- If forcing TCP_QUICKACK is enabled, set it after every recv()
      -- (see also http://stackoverflow.com/questions/1615447/disable-tcp-delayed-acks).
      -- Currently, this location is the only call to recv() in the package.
      -- If other direct calls to `NBS.recv` are added anywhere, this
      -- logic needs to be applied there as well!
      case tcpInternalForceQuickAck settings of
        Nothing -> return ()
#ifdef linux_HOST_OS
        Just forceVal -> do
          let val = if forceVal then 1 else 0
          N.setSocketOption sock (N.CustomSockOpt (6, 12)) val -- 6 is IPPROTO_TCP, 12 is TCP_QUICKACK
#else
        Just _forceVal -> return () -- Non-Linux OSs don't have TCP_QUICKACK.
#endif
      if BS.null bs
        then throwIO (userError "recvExact: Socket closed")
        else go (bs : acc) (l - fromIntegral (BS.length bs))

-- | Produce a HostName and ServiceName from a SockAddr. Only gives 'Just' for
-- IPv4 addresses.
decodeSockAddr :: N.SockAddr -> IO (Maybe (N.HostName, N.ServiceName))
decodeSockAddr sockAddr = case sockAddr of
  N.SockAddrInet port host -> do
    hostString <- N.inet_ntoa host
    return $ Just (hostString, show port)
  _ -> return Nothing

-- | Encode end point address
encodeEndPointAddress :: N.HostName
                      -> N.ServiceName
                      -> EndPointId
                      -> EndPointAddress
encodeEndPointAddress host port ix = EndPointAddress . BSC.pack $
  host ++ ":" ++ port ++ ":" ++ show ix

-- | Decode end point address
decodeEndPointAddress :: EndPointAddress
                      -> Maybe (N.HostName, N.ServiceName, EndPointId)
decodeEndPointAddress (EndPointAddress bs) =
  case splitMaxFromEnd (== ':') 2 $ BSC.unpack bs of
    [host, port, endPointIdStr] ->
      case reads endPointIdStr of
        [(endPointId, "")] -> Just (host, port, endPointId)
        _                  -> Nothing
    _ ->
      Nothing

-- | @spltiMaxFromEnd p n xs@ splits list @xs@ at elements matching @p@,
-- returning at most @p@ segments -- counting from the /end/
--
-- > splitMaxFromEnd (== ':') 2 "ab:cd:ef:gh" == ["ab:cd", "ef", "gh"]
splitMaxFromEnd :: (a -> Bool) -> Int -> [a] -> [[a]]
splitMaxFromEnd p = \n -> go [[]] n . reverse
  where
    -- go :: [[a]] -> Int -> [a] -> [[a]]
    go accs         _ []     = accs
    go ([]  : accs) 0 xs     = reverse xs : accs
    go (acc : accs) n (x:xs) =
      if p x then go ([] : acc : accs) (n - 1) xs
             else go ((x : acc) : accs) n xs
    go _ _ _ = error "Bug in splitMaxFromEnd"
