module LE.Networking where

import Protolude

import Control.Concurrent.STM
import Control.Concurrent.STM.TVar
import Network.Wai as W
import Network.Wai.Handler.Warp
import Network.HTTP.Types.Method
import Network.HTTP.Types.Status
import GHC.Generics
import Data.Aeson
import Data.Aeson.Types
import Data.Tagged
import Prelude(tail)

import qualified Data.ByteString.Lazy as BSL
import qualified Data.Sequence as Q
import qualified Data.Map as M

import LE.Types
import LE.Trading
import LE.Checks

le_port = 2345

type HandlerT a = (?req :: Request, ?respond :: (Response -> IO ResponseReceived), ?state :: Exchange) => a -> IO ResponseReceived
type Handler = HandlerT ()

data Request_ListOrders = Request_ListOrders {
  _reqListOrders_user :: Maybe UserId
  } deriving (Eq, Show, Generic)

data Request_CancelOrder = Request_CancelBid {
  _reqCancelOrder_bid :: Bid
  } | Request_CancelAsk {
  _reqCancelOrder_ask :: Ask
  } deriving (Eq, Show, Generic)

data Request_AddOrder = Request_AddBid {
  _reqAddOrder_bid :: Bid
  } | Request_AddAsk {
  _reqAddOrder_ask :: Ask
  } | Request_AddMBid {
  _reqAddOrder_mbid :: MBid
  } | Request_AddMAsk {
  _reqAddOrder_mask :: MAsk
  } deriving (Eq, Show, Generic)

data Request_CreateMoney = Request_CreateMoney {
  _reqCreateMoney_singleEntry :: SingleEntry
  } deriving (Eq, Show, Generic)

data Request_ListBalances = Request_ListBalances deriving (Eq, Show, Generic)

data Response_ListOrders = Response_ListOrders {
  _resListOrders_orders :: [LimitOrder]
  } deriving (Eq, Show, Generic)

data Response_CancelOrder = Response_CancelOrder deriving (Eq, Show, Generic)
data Response_AddOrder = Response_AddBid {
  _resAddOrder_trades :: [Trade]  
  } | Response_AddAsk {
  _resAddOrder_trades :: [Trade]
  } | Response_AddMBid {
  _resAddOrder_mbidRemainder :: Maybe MBid,
  _resAddOrder_trades        :: [Trade]
  } | Response_AddMAsk {
  _resAddOrder_maskRemainder :: Maybe MAsk,
  _resAddOrder_trades        :: [Trade]
  } deriving (Eq, Show, Generic)

data Response_CreateMoney = Response_CreateMoney deriving (Eq, Show, Generic)

data Response_ListBalances = Response_ListBalances {
  _resListBalances_externals :: [(UserId, Currency, Amount)],
  _resListBalances_internals :: [(UserId, Currency, Amount)],
  _resListBalances_helds     :: [(UserId, Currency, Amount)],
  _resListBalances_totalBals :: [(UserId, Currency, Amount)],
  _resListBalances_bookBals  :: [(Currency, Amount)]
  } deriving (Eq, Show, Generic)

serverMain :: IO ()
serverMain = do
  state <- initialize
  installSanityChecks state
  print $ encode $ Request_ListBalances
  putStrLn $ "Listening on " ++ show le_port
  run le_port $ \req respond ->
    let ?req = req
        ?respond = respond
        ?state = state
    in do
      print req
      body <- strictRequestBody req
      case (pathInfo req, requestMethod req) of
        ("createMoney" : _, "POST") -> withParsedRequest body api_createMoney
        ("listOrders" : _,  "POST") -> withParsedRequest body api_listOrders
        ("addOrder" : _,    "POST") -> withParsedRequest body api_addOrder
        ("cancelOrder" : _, "POST") -> withParsedRequest body api_cancelOrder
        ("listBalances" : _, "POST") -> withParsedRequest body api_listBalances
        _ -> respond (W.responseLBS status404 [] "Unknown path")

withParsedRequest :: FromJSON a => BSL.ByteString -> HandlerT (a -> IO ResponseReceived)
withParsedRequest bs handler = case decode bs of
  Nothing -> ?respond (W.responseLBS status400 [] "Unable to parse")
  Just x -> handler x

initialize :: IO Exchange
initialize = Exchange <$> newTVarIO Q.empty <*> newTVarIO (newBook ("USD", "BTC")) <*> newTVarIO Q.empty

api_createMoney :: HandlerT Request_CreateMoney
api_createMoney Request_CreateMoney{..} = do
  let Exchange{..} = ?state
  atomically $ modifyTVar _exchange_external $
    (Q.|> Tagged _reqCreateMoney_singleEntry)
  ?respond $ W.responseLBS status200 [] $ encode $ Response_CreateMoney

api_listOrders :: HandlerT Request_ListOrders
api_listOrders _ = do
  let Exchange{..} = ?state
  book <- readTVarIO _exchange_book
  ?respond $ W.responseLBS status200 [] $ encode $ Response_ListOrders $ toList book

api_listBalances :: HandlerT Request_ListOrders
api_listBalances _ = do
  res <- atomically $ do
    userExternals <- destructBalances <$> userExternalBalances ?state
    userInternals <- destructBalances <$> userInternalBalances ?state
    userHelds     <- destructBalances <$> userHeldBalances ?state
    userBals <- destructBalances <$> userBalances ?state
    bookBals <- M.toList <$> bookBalances ?state
    return $ Response_ListBalances userExternals userInternals userHelds userBals bookBals
  ?respond $ W.responseLBS status200 [] $ encode res

api_cancelOrder :: HandlerT Request_CancelOrder
api_cancelOrder req = do
  let Exchange{..} = ?state
  atomically $ modifyTVar' _exchange_book $ case req of
        Request_CancelBid bid -> cancelBid bid
        Request_CancelAsk ask -> cancelAsk ask
  ?respond $ W.responseLBS status200 [] "OK"
  
api_addOrder :: HandlerT Request_AddOrder
api_addOrder req = do
  let Exchange{..} = ?state
  case req of
    Request_AddBid bid -> do
      res <- atomically $ do
        book <- readTVar _exchange_book
        let (trades, newBook) = fillBid bid book
        writeTVar _exchange_book newBook
        return $ Response_AddBid trades
      ?respond $ W.responseLBS status200 [] $ encode res
    Request_AddAsk ask -> do
      res <- atomically $ do
        book <- readTVar _exchange_book
        let (trades, newBook) = fillAsk ask book
        writeTVar _exchange_book newBook
        return $ Response_AddAsk trades
      ?respond $ W.responseLBS status200 [] $ encode res
    Request_AddMBid mbid -> do
      allBalances <- atomically $ userBalances ?state
      let user = _morder_user $ unTagged mbid
      case M.lookup user allBalances of
        Nothing -> ?respond $ W.responseLBS status400 [] "No balance"
        Just balances -> do
          res <- atomically $ do
            book <- readTVar _exchange_book
            let (bidRemainder, trades, newBook) = tryFillMBid mbid balances book
            writeTVar _exchange_book newBook
            return $ Response_AddMBid bidRemainder trades
          ?respond $ W.responseLBS status200 [] $ encode res
    Request_AddMAsk mask -> do
      allBalances <- atomically $ userBalances ?state
      let user = _morder_user $ unTagged mask
      case M.lookup user allBalances of
        Nothing -> ?respond $ W.responseLBS status400 [] "No balance"
        Just balances -> do
          res <- atomically $ do
            book <- readTVar _exchange_book
            let (askRemainder, trades, newBook) = tryFillMAsk mask balances book
            writeTVar _exchange_book newBook
            return $ Response_AddMAsk askRemainder trades
          ?respond $ W.responseLBS status200 [] $ encode res

instance FromJSON LimitOrder where
  parseJSON = genericParseJSON customOptions
instance FromJSON MarketOrder where
  parseJSON = genericParseJSON customOptions
instance ToJSON LimitOrder where
  toJSON = genericToJSON customOptions
instance ToJSON MarketOrder where
  toJSON = genericToJSON customOptions

customOptions = defaultOptions { fieldLabelModifier = Prelude.tail . dropWhile (/= '_') . Prelude.tail }

instance FromJSON Request_ListOrders where
  parseJSON = genericParseJSON customOptions
instance FromJSON Request_CancelOrder where
  parseJSON = genericParseJSON customOptions
instance FromJSON Request_AddOrder where
  parseJSON = genericParseJSON customOptions
instance FromJSON Request_CreateMoney where
  parseJSON = genericParseJSON customOptions
instance FromJSON Request_ListBalances where
  parseJSON = genericParseJSON customOptions
instance FromJSON Response_ListOrders where
  parseJSON = genericParseJSON customOptions
instance FromJSON Response_CancelOrder where
  parseJSON = genericParseJSON customOptions
instance FromJSON Response_AddOrder where
  parseJSON = genericParseJSON customOptions
instance FromJSON Response_CreateMoney where
  parseJSON = genericParseJSON customOptions
instance FromJSON Response_ListBalances where
  parseJSON = genericParseJSON customOptions
instance FromJSON Trade where
  parseJSON = genericParseJSON customOptions
instance FromJSON DoubleEntry where
  parseJSON = genericParseJSON customOptions
instance FromJSON SingleEntry where
  parseJSON = genericParseJSON customOptions

instance ToJSON Request_ListOrders where
  toJSON = genericToJSON customOptions
instance ToJSON Request_CancelOrder where
  toJSON = genericToJSON customOptions
instance ToJSON Request_AddOrder where
  toJSON = genericToJSON customOptions
instance ToJSON Request_CreateMoney where
  toJSON = genericToJSON customOptions
instance ToJSON Request_ListBalances where
  toJSON = genericToJSON customOptions
instance ToJSON Response_ListOrders where
  toJSON = genericToJSON customOptions
instance ToJSON Response_CancelOrder where
  toJSON = genericToJSON customOptions
instance ToJSON Response_AddOrder where
  toJSON = genericToJSON customOptions
instance ToJSON Response_CreateMoney where
  toJSON = genericToJSON customOptions
instance ToJSON Response_ListBalances where
  toJSON = genericToJSON customOptions
instance ToJSON Trade where
  toJSON = genericToJSON customOptions
instance ToJSON DoubleEntry where
  toJSON = genericToJSON customOptions
instance ToJSON SingleEntry where
  toJSON = genericToJSON customOptions
