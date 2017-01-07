import Control.Monad (forM_, when)
import Data.String (fromString)
import Network.Transport
import Network.Transport.TCP
import Control.Concurrent.MVar
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async
import Debug.Trace

main = do

  Right (transport, internals) <-
    createTransportExposeInternals "127.0.0.1" "7777" defaultTCPParameters

  m <- newMVar ()
  let myPolicy :: Policy
      myPolicy _ = PolicyDecision $ do
        continue m
        where
        continue m = pure (Block (readMVar m), PolicyDecision (continue m))

  let block :: IO ()
      block = takeMVar m
  let accept :: IO ()
      accept = putMVar m ()

  Right receiver <- newEndPointInternal internals myPolicy
  Right sender <- newEndPoint transport

  let receiveMessages = do
        ev <- receive receiver
        case ev of
          EndPointClosed -> pure ()
          ConnectionOpened _ _ addr -> do
            putStrLn "Connection opened"
            receiveMessages
          ConnectionClosed _ -> do
            putStrLn "Connection closed"
            receiveMessages
          Received _ _ -> do
            putStrLn "Received"
            receiveMessages
          _ -> putStrLn "Other" >> receiveMessages

  let sendMessages n = do
        Right conn <- connect sender (address receiver) ReliableOrdered defaultConnectHints
        putStrLn $ "Connected and sending " ++ show n
        send conn [fromString (show n)]
        close conn
        sendMessages (n + 1)

  -- User input handler. Stops if you input "q", otherwise a string which
  -- parses to an Int is expected, and traffic will be accepted for that many
  -- milliseconds.
  let userInput = do
        line <- getLine
        case line of
          "q" -> pure ()
          other -> do
            let n = read other :: Int
            accept
            threadDelay (n * 1000)
            block
            userInput

  -- First, block traffic
  block

  senderThread <- async (sendMessages 0)
  receiverThread <- async receiveMessages

  -- Now allow the user to unblock by entering a number.
  userInput

  _ <- cancel receiverThread
  _ <- cancel senderThread

  closeEndPoint sender
  closeEndPoint receiver

  closeTransport transport

  pure ()
