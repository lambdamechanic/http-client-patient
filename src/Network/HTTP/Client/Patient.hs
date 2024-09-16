{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE FlexibleContexts #-}

module Network.HTTP.Client.Patient (
    retryPatiently, withRetry
) where

import Network.HTTP.Client
    ( getOriginalRequest,
      BodyReader,
      ManagerSettings(managerRetryableException, managerModifyRequest,
                      managerModifyResponse),
      Request(requestHeaders, host),
      Response(responseHeaders, responseStatus) )
import Network.HTTP.Types.Status (statusCode)
import Control.Concurrent.STM
    ( atomically, newTVarIO, readTVar, writeTVar, modifyTVar', TVar )
import Control.Concurrent (threadDelay)
import Control.Monad (when, unless)
import Data.Time.Clock
    ( addUTCTime, diffUTCTime, getCurrentTime, UTCTime )
import qualified Data.Map.Strict as Map
import qualified Data.ByteString.Char8 as BS
import Data.CaseInsensitive qualified as CI
import Control.Exception (Exception, throwIO, fromException, SomeException)
import Data.Typeable (Typeable)
import Network.HTTP.Types.Header (HeaderName, Header)
import Data.UUID.V4 (nextRandom)
import Data.Bifunctor (first)
import Data.Foldable (forM_)
import Debug.Trace (trace, traceM)
import Control.Exception.Lifted(catch)
import Control.Monad.Trans.Control(MonadBaseControl)
-- Types and Exceptions
type Domain = String
type RetryAfterTime = UTCTime
type DomainBlocker = TVar (Map.Map Domain RetryAfterTime)
type RetryCounts = TVar (Map.Map BS.ByteString Int)

data RetryAfterException = RetryAfterException
    deriving (Show, Typeable,Eq)

instance Exception RetryAfterException


withRetry :: MonadBaseControl IO m => m a -> m a
withRetry action = action `catch` handler
  where
    handler RetryAfterException = do
        traceM "got a retry! trying again."
        withRetry action


-- Main Function to Add Retry-After Handling
retryPatiently :: Int -> ManagerSettings -> IO ManagerSettings
retryPatiently maxRetries settings = do
    blocker <- newTVarIO Map.empty
    retryCounts <- newTVarIO Map.empty
    let newSettings = settings
            { managerModifyRequest = combineModifyRequest (managerModifyRequest settings) (modifyRequest blocker)
            , managerModifyResponse = combineModifyResponse (managerModifyResponse settings) (modifyResponse blocker retryCounts maxRetries)
            }
    return newSettings

-- Combining User and Our Functions
combineModifyRequest :: (Request -> IO Request) -> (Request -> IO Request) -> (Request -> IO Request)
combineModifyRequest userFunc ourFunc req = userFunc req >>= ourFunc

combineModifyResponse :: (Response BodyReader -> IO (Response BodyReader)) -> (Response BodyReader -> IO (Response BodyReader)) -> (Response BodyReader -> IO (Response BodyReader))
combineModifyResponse userFunc ourFunc res = userFunc res >>= ourFunc

-- Modify Request
modifyRequest :: DomainBlocker -> Request -> IO Request
modifyRequest blocker req = do
    let domain = extractDomain req
    waitIfBlocked blocker domain
    addRequestID req

waitIfBlocked :: DomainBlocker -> Domain -> IO ()
waitIfBlocked blocker domain = do
    mRetryAfter <- atomically $ do
        domainMap <- readTVar blocker
        return $ Map.lookup domain domainMap
    case mRetryAfter of
        Nothing -> return ()  -- Domain is not blocked
        Just retryAfter -> do
            now <- getCurrentTime
            if now >= retryAfter
                then atomically $ modifyTVar' blocker (Map.delete domain)  -- Unblock domain
                else do
                    let waitTime = diffUTCTime retryAfter now
                    threadDelay $ floor (waitTime * 1e6)  -- Wait until unblock time
                    waitIfBlocked blocker domain  -- Recheck after waiting

-- Modify Response
modifyResponse :: DomainBlocker -> RetryCounts -> Int -> Response BodyReader -> IO (Response BodyReader)
modifyResponse blocker retryCounts maxRetries res = do
    let status = statusCode $ responseStatus res
    when (status == 429) $ do
        now <- getCurrentTime
        let domain = extractDomainFromResponse res
        forM_ (lookupRetryAfter now res) $ \retryAfter -> do
            atomically $ modifyTVar' blocker $ Map.insert domain retryAfter
            -- Increment retry count
            let req = getOriginalRequest res
            mRequestID <- getRequestID req
            forM_ mRequestID $ \requestID -> do
                retries <- atomically $ do
                    counts <- readTVar retryCounts
                    let currentRetries = Map.findWithDefault 0 requestID counts
                    let newRetries = currentRetries + 1
                    writeTVar retryCounts $ Map.insert requestID newRetries counts
                    return newRetries
                if retries > maxRetries
                    then print ("giving up on 429 retries"::String, requestID, extractDomain req, retries)
                    else do
                      print ("Retrying after 429"::String, requestID, extractDomain req, retries)
                      throwIO RetryAfterException
    return res


-- Parse Retry-After Header
lookupRetryAfter :: UTCTime -> Response a -> Maybe RetryAfterTime
lookupRetryAfter now res = do
    let headers = responseHeaders res
        retryAfterHeader = lookupHeaderCaseInsensitive "Retry-After" headers
    retryAfterHeader >>= parseRetryAfter now

lookupHeaderCaseInsensitive :: HeaderName -> [Header] -> Maybe BS.ByteString
lookupHeaderCaseInsensitive name headers =
    let nameCI = CI.mk name
    in lookup nameCI $ map (first CI.mk) headers

parseRetryAfter :: UTCTime -> BS.ByteString -> Maybe RetryAfterTime
parseRetryAfter now headerValue = (\(seconds,_) -> addUTCTime (fromIntegral seconds) now)
   <$> BS.readInt headerValue

-- Extract Domain
extractDomain :: Request -> Domain
extractDomain req = BS.unpack $ host req

extractDomainFromResponse :: Response a -> Domain
extractDomainFromResponse =  extractDomain . getOriginalRequest

-- Request ID Handling
requestIDHeaderName :: HeaderName
requestIDHeaderName = "X-Request-ID"

addRequestID :: Request -> IO Request
addRequestID req = do
    let existingID = lookupHeaderCaseInsensitive requestIDHeaderName (requestHeaders req)
    case existingID of
        Just _ -> return req  -- Request ID already present
        Nothing -> do
            uuid <- nextRandom
            let newHeaders = (requestIDHeaderName, BS.pack $ show uuid) : requestHeaders req
            return req { requestHeaders = newHeaders }

getRequestID :: Request -> IO (Maybe BS.ByteString)
getRequestID req = return $ lookupHeaderCaseInsensitive requestIDHeaderName (requestHeaders req)

