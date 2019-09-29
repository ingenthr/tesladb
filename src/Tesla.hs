{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Tesla
    ( authenticate, AuthResponse(..), vehicles, AuthInfo(..), fromToken, vehicleData, VehicleData
    ) where


import           Control.Lens
import           Control.Monad          ((<=<))
import           Data.Aeson             (FromJSON (..), Options (..),
                                         Value (..), defaultOptions,
                                         fieldLabelModifier, genericParseJSON)
import           Data.Aeson.Lens        (key, values)
import qualified Data.ByteString.Char8  as BC
import qualified Data.ByteString.Lazy   as BL
import           Data.Map.Strict        (Map)
import qualified Data.Map.Strict        as Map
import           Data.Maybe             (fromJust)
import           Data.Text              (Text)
import           Generics.Deriving.Base (Generic)
import           Network.Wreq           (FormParam (..), Options, Response,
                                         asJSON, defaults, getWith, header,
                                         postWith, responseBody)

baseURL :: String
baseURL = "https://owner-api.teslamotors.com/"
authURL :: String
authURL = baseURL <> "oauth/token"
vehiclesURL :: String
vehiclesURL = baseURL <> "api/1/vehicles"

vehicleURL :: String -> String
vehicleURL vid = mconcat [baseURL, "api/1/vehicles/", vid, "/vehicle_data"]

userAgent :: BC.ByteString
userAgent = "github.com/dustin/tesladb 0.1"

defOpts :: Network.Wreq.Options
defOpts = defaults & header "User-Agent" .~ [userAgent]

data AuthInfo = AuthInfo {
  _clientID       :: String
  , _clientSecret :: String
  , _email        :: String
  , _password     :: String
  , _bearerToken  :: String
  } deriving(Show)

fromToken :: String -> AuthInfo
fromToken t = AuthInfo{_bearerToken=t, _clientID="", _clientSecret="", _email="", _password=""}

jsonOpts :: Data.Aeson.Options
jsonOpts = defaultOptions {
  fieldLabelModifier = dropWhile (== '_')
  }

data AuthResponse = AuthResponse {
  _access_token    :: String
  , _expires_in    :: Int
  , _refresh_token :: String
  } deriving(Generic, Show)

instance FromJSON AuthResponse where
  parseJSON = genericParseJSON jsonOpts

authenticate :: AuthInfo -> IO AuthResponse
authenticate AuthInfo{..} = do
  r <- asJSON =<< postWith defOpts authURL ["grant_type" := ("password" :: String),
                                            "client_id" := _clientID,
                                            "client_secret" := _clientSecret,
                                            "email" := _email,
                                            "password" := _password] :: IO (Response AuthResponse)
  pure $ r ^. responseBody

authOpts :: AuthInfo -> Network.Wreq.Options
authOpts AuthInfo{..} = defOpts & header "Authorization" .~ ["Bearer " <> BC.pack _bearerToken]

-- Vehicle name -> vehicle ID
vehicles :: AuthInfo -> IO (Map Text Text)
vehicles ai = do
  r <- asJSON =<< getWith (authOpts ai) vehiclesURL :: IO (Response Value)
  let vals = r ^.. responseBody . key "response" . values . key "id_s"
      keys = r ^.. responseBody . key "response" . values . key "display_name"
  pure (Map.fromList $ zip (s <$> keys) (s <$> vals))

  where
    s (String x) = x
    s _          = ""

type VehicleData = BL.ByteString

vehicleData :: AuthInfo -> String -> IO VehicleData
vehicleData ai vid = do
  r <- getWith (authOpts ai) (vehicleURL vid)
  pure . fromJust . inner $ r ^. responseBody
    where inner = BL.stripPrefix "{\"response\":" <=< BL.stripSuffix "}"
