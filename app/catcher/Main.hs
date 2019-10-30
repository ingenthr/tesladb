{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Main where

import           Data.Maybe             (fromJust)
import           Data.Text              (Text)
import           Data.Time.Format       (defaultTimeLocale, formatTime)
import           Data.Time.LocalTime    (getCurrentTimeZone, utcToLocalTime)
import           Data.Word              (Word32)
import           Database.SQLite.Simple hiding (bind, close)
import           Network.MQTT.Client
import           Network.MQTT.Types     (RetainHandling (..))
import           Network.URI
import           Options.Applicative    (Parser, auto, execParser, fullDesc,
                                         help, helper, info, long, maybeReader,
                                         option, progDesc, showDefault,
                                         strOption, switch, value, (<**>))
import           System.Log.Logger      (Priority (DEBUG), debugM,
                                         rootLoggerName, setLevel,
                                         updateGlobalLogger)

import           Tesla
import           TeslaDB

data Options = Options {
  optDBPath         :: String
  , optMQTTURI      :: URI
  , optMQTTTopic    :: Text
  , optSessionTime  :: Word32
  , optCleanSession :: Bool
  }

options :: Parser Options
options = Options
  <$> strOption (long "dbpath" <> showDefault <> value "tesla.db" <> help "tesladb path")
  <*> option (maybeReader parseURI) (long "mqtt-uri" <> showDefault <> value (fromJust $ parseURI "mqtt://localhost/") <> help "mqtt broker URI")
  <*> strOption (long "mqtt-topic" <> showDefault <> value "tmp/tesla" <> help "MQTT topic")
  <*> option auto (long "session-expiry" <> showDefault <> value 3600 <> help "Session expiration")
  <*> switch (long "clean-session" <> help "Clean the MQTT session")

run :: Options -> IO ()
run Options{..} = do
  updateGlobalLogger rootLoggerName (setLevel DEBUG)

  withConnection optDBPath storeThings

  where
    sink db _ _ m _ = do
      tz <- getCurrentTimeZone
      let lt = utcToLocalTime tz . teslaTS $ m
      debugM rootLoggerName $ mconcat ["Received data ", formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S%Q %Z" lt]
      insertVData db m

    storeThings db = do
      dbInit db

      mc <- connectURI mqttConfig{_cleanSession=False,
                                  _protocol=Protocol50,
                                  _msgCB=SimpleCallback (sink db),
                                  _connProps=[PropReceiveMaximum 65535,
                                              PropSessionExpiryInterval optSessionTime,
                                              PropTopicAliasMaximum 10,
                                              PropRequestResponseInformation 1,
                                              PropRequestProblemInformation 1]}
            optMQTTURI
      props <- svrProps mc
      debugM rootLoggerName $ mconcat ["MQTT connected: ", show props]
      subr <- subscribe mc [(optMQTTTopic, subOptions{_subQoS=QoS2, _retainHandling=SendOnSubscribeNew})] mempty
      debugM rootLoggerName $ mconcat ["Sub response: ", show subr]

      waitForClient mc

main :: IO ()
main = run =<< execParser opts

  where opts = info (options <**> helper)
          ( fullDesc <> progDesc "sink tesladb from mqtt")
