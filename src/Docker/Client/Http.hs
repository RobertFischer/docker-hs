{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Docker.Client.Http where

-- import           Control.Monad.Base           (MonadBase(..), liftBaseDefault)
import           Control.Monad.Catch          (MonadMask (..))
#if MIN_VERSION_http_conduit(2,3,0)
import           Control.Monad.IO.Unlift      (MonadUnliftIO)
#endif
import           Control.Monad.Reader         (ReaderT (..), runReaderT)
import qualified Data.ByteString.Char8        as BSC
import qualified Data.ByteString.Lazy         as BL
import           Data.Conduit                 (Sink)
import           Data.Default.Class           (def)
import           Data.Maybe                   (fromMaybe)
import           Data.Monoid                  ((<>))
import           Data.X509                    (CertificateChain (..))
import           Data.X509.CertificateStore   (makeCertificateStore)
import           Data.X509.File               (readKeyFile, readSignedObject)
import           Network.HTTP.Client          (defaultManagerSettings,
                                               managerRawConnection, method,
                                               newManager, parseRequest,
                                               requestBody, requestHeaders)
import qualified Network.HTTP.Client          as HTTP
import           Network.HTTP.Client.Internal (makeConnection)
import qualified Network.HTTP.Simple          as NHS
import           Network.HTTP.Types           (StdMethod, status101, status200,
                                               status201, status204)
import           Network.TLS                  (ClientHooks (..),
                                               ClientParams (..), Shared (..),
                                               Supported (..),
                                               defaultParamsClient)
import           Network.TLS.Extra            (ciphersuite_strong)
import           System.X509                  (getSystemCertificateStore)

import           Control.Monad.Catch          (try)
import           Control.Monad.Except
import           Control.Monad.Reader.Class
import           Data.Text                    as T
import           Data.Typeable                (Typeable)
import qualified Network.HTTP.Types           as HTTP
import qualified Network.Socket               as S
import qualified Network.Socket.ByteString    as SBS


import           Docker.Client.Internal       (getEndpoint,
                                               getEndpointContentType,
                                               getEndpointHeaders,
                                               getEndpointRequestBody)
import           Docker.Client.Types          (DockerClientOpts, Endpoint (..),
                                               apiVer, baseUrl)

type Request = HTTP.Request
type Response = HTTP.Response BL.ByteString
type HttpVerb = StdMethod
newtype HttpHandler m = HttpHandler (forall a . Request -> (HTTP.Response () -> Sink BSC.ByteString m (Either DockerError a)) -> m (Either DockerError a))

data DockerError = DockerConnectionError NHS.HttpException
                 | DockerInvalidRequest Endpoint
                 | DockerClientError Text
                 | DockerClientDecodeError Text -- ^ Could not parse the response from the Docker endpoint.
                 | DockerInvalidStatusCode HTTP.Status -- ^ Invalid exit code received from Docker endpoint.
                 | GenericDockerError Text deriving (Show, Typeable)

newtype DockerT m a = DockerT {
        unDockerT :: Monad m => ReaderT (DockerClientOpts, HttpHandler m) m a
    } deriving (Functor) -- Applicative, Monad, MonadReader, MonadError, MonadTrans

instance Applicative m => Applicative (DockerT m) where
    pure a = DockerT $ pure a
    (<*>) (DockerT f) (DockerT v) =  DockerT $ f <*> v

instance Monad m => Monad (DockerT m) where
    (DockerT m) >>= f = DockerT $ m >>= unDockerT . f
    return = pure

instance Monad m => MonadReader (DockerClientOpts, HttpHandler m) (DockerT m) where
    ask = DockerT ask
    local f (DockerT m) = DockerT $ local f m

instance MonadTrans DockerT where
    lift m = DockerT $ lift m

instance MonadIO m => MonadIO (DockerT m) where
    liftIO = lift . liftIO

-- instance MonadBase IO m => MonadBase IO (DockerT m) where
--     liftBase = liftBaseDefault

runDockerT :: Monad m => (DockerClientOpts, HttpHandler m) -> DockerT m a -> m a
runDockerT (opts, h) r = runReaderT (unDockerT r) (opts, h)

-- The reason we return Maybe Request is because the parseURL function
-- might find out parameters are invalid and will fail to build a Request
-- Since we are the ones building the Requests this shouldn't happen, but would
-- benefit from testing that on all of our Endpoints
mkHttpRequest :: HttpVerb -> Endpoint -> DockerClientOpts -> Maybe Request
mkHttpRequest verb endpoint opts =
  fmap setRequestFields . parseRequest . T.unpack $ fullEndpoint
  where
    fullEndpoint = baseUrl opts <> getEndpoint (apiVer opts) endpoint

    -- Note: Do we need to set length header?
    setRequestFields request = request
      { method = HTTP.renderStdMethod verb
      , requestHeaders =
          ("Content-Type", getEndpointContentType endpoint) : getEndpointHeaders endpoint
        -- This will either be a HTTP.RequestBodyLBS or
        -- HTTP.RequestBodySourceChunked for the build endpoint
      , requestBody =
          fromMaybe (requestBody request) (getEndpointRequestBody endpoint)
      }

defaultHttpHandler :: (
#if MIN_VERSION_http_conduit(2,3,0)
    MonadUnliftIO m, 
#endif
    MonadIO m, MonadMask m) => m (HttpHandler m)
defaultHttpHandler = do
    manager <- liftIO $ newManager defaultManagerSettings
    return $ httpHandler manager

httpHandler :: (
#if MIN_VERSION_http_conduit(2,3,0)
    MonadUnliftIO m, 
#endif
    MonadIO m, MonadMask m) => HTTP.Manager -> HttpHandler m
httpHandler manager = HttpHandler $ \request' sink -> do -- runResourceT ..
    let request = NHS.setRequestManager manager request'
    try (NHS.httpSink request sink) >>= \res -> case res of
        Right res                              -> return res
#if MIN_VERSION_http_client(0,5,0)
        Left e@(HTTP.HttpExceptionRequest _ HTTP.ConnectionFailure{})  -> return $ Left $ DockerConnectionError e
#else
        Left e@HTTP.FailedConnectionException{}  -> return $ Left $ DockerConnectionError e
        Left e@HTTP.FailedConnectionException2{} -> return $ Left $ DockerConnectionError e
#endif
        Left e                                 -> return $ Left $ GenericDockerError (T.pack $ show e)

-- | Connect to a unix domain socket (the default docker socket is
--   at \/var\/run\/docker.sock)
--
--   Docker seems to ignore the hostname in requests sent over unix domain
--   sockets (and the port obviously doesn't matter either)
unixHttpHandler :: (
#if MIN_VERSION_http_conduit(2,3,0)
    MonadUnliftIO m, 
#endif
    MonadIO m, MonadMask m) => FilePath -- ^ The socket to connect to
                -> m (HttpHandler m)
unixHttpHandler fp = do
  let mSettings = defaultManagerSettings
                    { managerRawConnection = return $ openUnixSocket fp}
  manager <- liftIO $ newManager mSettings
  return $ httpHandler manager

  where
    openUnixSocket filePath _ _ _ = do
      s <- S.socket S.AF_UNIX S.Stream S.defaultProtocol
      S.connect s (S.SockAddrUnix filePath)
      makeConnection (SBS.recv s 8096)
                     (SBS.sendAll s)
                     (S.close s)

-- TODO:
--  Move this to http-client-tls or network?
--  Add CA.
--  Maybe change this to: HostName -> PortNumber -> ClientParams -> IO (Either String TLSSettings)
clientParamsWithClientAuthentication :: S.HostName -> S.PortNumber -> FilePath -> FilePath -> IO (Either String ClientParams)
clientParamsWithClientAuthentication host port keyFile certificateFile = do
    keys <- readKeyFile keyFile
    cert <- readSignedObject certificateFile
    case keys of
        [key] ->
            -- TODO: load keys/path from file
            let params = (defaultParamsClient host $ BSC.pack $ show port) {
                    clientHooks = def
                        { onCertificateRequest = \_ -> return (Just (CertificateChain cert, key))}
                  , clientSupported = def
                        { supportedCiphers = ciphersuite_strong}
                  }
            in
            return $ Right params
        _ ->
            return $ Left $ "Could not read key file: " ++ keyFile

clientParamsSetCA :: ClientParams -> FilePath -> IO ClientParams
clientParamsSetCA params path = do
    userStore <- makeCertificateStore <$> readSignedObject path
    systemStore <- getSystemCertificateStore
    let store = userStore <> systemStore
    let oldShared = clientShared params
    return $ params { clientShared = oldShared
            { sharedCAStore = store }
        }


-- If the status is an error, returns a Just DockerError. Otherwise, returns Nothing.
statusCodeToError :: Endpoint -> HTTP.Status -> Maybe DockerError
statusCodeToError endpoint status
  | status `elem` expectedStatuses
  = Nothing
  | otherwise
  = Just $ DockerInvalidStatusCode status
  where
    expectedStatuses = case endpoint of
      VersionEndpoint          {} -> [status200]
      ListContainersEndpoint   {} -> [status200]
      ListImagesEndpoint       {} -> [status200]
      CreateContainerEndpoint  {} -> [status201]
      StartContainerEndpoint   {} -> [status204]
      StopContainerEndpoint    {} -> [status204]
      WaitContainerEndpoint    {} -> [status200]
      KillContainerEndpoint    {} -> [status204]
      RestartContainerEndpoint {} -> [status204]
      PauseContainerEndpoint   {} -> [status204]
      UnpauseContainerEndpoint {} -> [status204]
      ContainerLogsEndpoint    {} -> [status200, status101]
      DeleteContainerEndpoint  {} -> [status204]
      InspectContainerEndpoint {} -> [status200]
      BuildImageEndpoint       {} -> [status200]
      CreateImageEndpoint      {} -> [status200]
      DeleteImageEndpoint      {} -> [status200]
      CreateNetworkEndpoint    {} -> [status201]
      RemoveNetworkEndpoint    {} -> [status204]
