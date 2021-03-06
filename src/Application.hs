{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE ViewPatterns          #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Application
  ( getApplicationDev
  , appMain
  , develMain
  , makeFoundation
  , makeLogWare
    -- * for DevelMain
  , getApplicationRepl
  , shutdownApp
    -- * for GHCI
  , handler
  , db
  , getDbConnectionString
  ) where

import           Control.Monad.Logger (liftLoc, runLoggingT)
import           Data.ByteString.Char8 (pack)
import           Data.Default
import           Database.Persist.Postgresql (createPostgresqlPool, runSqlPool)
import           Handler.About
import           Handler.Admin
import           Handler.Auth
import           Handler.Common
import           Handler.Company
import           Handler.CompanyDetails
import           Handler.CompanyList
import           Handler.Historical
import           Handler.Home
import           Handler.LogViewer
import           Handler.Profile
import           Handler.SearchArticles
import           Handler.SearchCompanies
import           Handler.StoryDetails
import           Handler.StoryList
import           Helper.Fixtures as F
import           Import
import           Language.Haskell.TH.Syntax (qLocation)
import           Network.HTTP.Client (defaultManagerSettings, newManager)
import           Network.Wai (Middleware)
import           Network.Wai.Handler.Warp (Settings, defaultSettings, defaultShouldDisplayException,
                                           getPort, setHost, setOnException, setPort)
import           Network.Wai.Handler.WarpTLS
import           Network.Wai.Middleware.RequestLogger (Destination (Logger), IPAddrSource (..),
                                                       OutputFormat (..), destination,
                                                       mkRequestLogger, outputFormat)
import           System.Environment (getEnv)
import           System.Log.FastLogger (defaultBufSize, newStdoutLoggerSet, toLogStr)
import           Universum

mkYesodDispatch "App" resourcesApp

makeFoundation :: AppSettings -> IO App
makeFoundation appSettings = do
  appHttpManager <- newManager defaultManagerSettings
  appLogger <- newStdoutLoggerSet defaultBufSize >>= makeYesodLogger
  appStatic <-
    (if appMutableStatic appSettings
       then staticDevel
       else static)
      (appStaticDir appSettings)
  let mkFoundation appConnPool = App {..}
      tempFoundation = mkFoundation $ error "connPool forced in tempFoundation"
      logFunc = messageLoggerSource tempFoundation appLogger
  dbConnStr <- getEnv "iiservant"
  pool <-
    flip runLoggingT logFunc $
    createPostgresqlPool (pack dbConnStr) 10
  runLoggingT (runSqlPool (runMigration migrateAll) pool) logFunc
  return $ mkFoundation pool

makeApplication :: App -> IO Application
makeApplication foundation = do
  logWare <- makeLogWare foundation
  appPlain <- toWaiAppPlain foundation
  return $ logWare $ defaultMiddlewaresNoLogging appPlain

makeLogWare :: App -> IO Middleware
makeLogWare foundation =
  mkRequestLogger
    def
    { outputFormat =
        if appDetailedRequestLogging $ appSettings foundation
          then Detailed True
          else Apache
                 (if appIpFromHeader $ appSettings foundation
                    then FromFallback
                    else FromSocket)
    , destination = Logger $ loggerSet $ appLogger foundation
    }

-- | Warp settings for the given foundation value.
warpSettings :: App -> Settings
warpSettings foundation =
  setPort (appPort $ appSettings foundation) $
  setHost (appHost $ appSettings foundation) $
  setOnException
    (\_req e ->
       when (defaultShouldDisplayException e) $
       messageLoggerSource
         foundation
         (appLogger foundation)
         $(qLocation >>= liftLoc)
         "yesod"
         LevelError
         (toLogStr $ "Exception from Warp: " ++ show e))
    defaultSettings

-- | For yesod devel, return the Warp settings and WAI Application.
getApplicationDev :: IO (Settings, Application)
getApplicationDev = do
  (foundation, wsettings) <- getEssentials
  app <- makeApplication foundation
  F.runInsertAdminsAction
  -- _ <- withAsync \_ -> threader
  return (wsettings, app)

getAppSettings :: IO AppSettings
getAppSettings = loadYamlSettings [configSettingsYml] [] useEnv

-- | main function for use by yesod devel
develMain :: IO ()
develMain = develMainHelper getApplicationDev

tlsS :: TLSSettings
tlsS =
  tlsSettings
    "/etc/letsencrypt/live/investments-info.com/fullchain.pem"
    "/etc/letsencrypt/live/investments-info.com/privkey.pem"

-- | The @main@ function for an executable running this site.
appMain :: IO ()
appMain = do
  (foundation, _) <- getEssentials
  app <- makeApplication foundation
  F.runInsertAdminsAction
  runTLS tlsS (warpSettings foundation) app
  -- runSettings (warpSettings foundation) app

--------------------------------------------------------------
-- Functions for DevelMain.hs (a way to run the app from GHCi)
--------------------------------------------------------------
getApplicationRepl :: IO (Int, App, Application)
getApplicationRepl = do
  (foundation, wsettings) <- getEssentials
  app1 <- makeApplication foundation
  return (getPort wsettings, foundation, app1)

shutdownApp :: App -> IO ()
shutdownApp _ = pass

---------------------------------------------
-- Functions for use in development with GHCi
---------------------------------------------
-- | Run a handler
handler :: Handler a -> IO a
handler h = getAppSettings >>= makeFoundation >>= flip unsafeHandler h

-- | Run DB queries
db :: ReaderT SqlBackend Handler a -> IO a
db = handler . runDB

getDbConnectionString :: IO ByteString
getDbConnectionString =
  pack <$> getEnv "iiservant"

getEssentials :: IO (App, Settings)
getEssentials = do
  settings <- getAppSettings
  -- main: settings <- loadYamlSettingsArgs [configSettingsYmlValue] useEnv
  foundation <- makeFoundation settings
  wsettings <- getDevSettings $ warpSettings foundation
  return (foundation, wsettings)

