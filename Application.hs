{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# LANGUAGE FlexibleInstances #-}
module Application
    ( getApplication
    , getApplicationDev
    ) where

import Import
import Settings
import Yesod.Default.Config
import Yesod.Default.Main
import Yesod.Default.Handlers
import Network.Wai.Middleware.Gzip
import Network.Wai.Middleware.Autohead
import Book.Routes
import Network.Wai.Middleware.RequestLogger
import Data.Maybe (fromMaybe)
import Data.IORef (newIORef, writeIORef)
import System.Process (runProcess, waitForProcess)
import Yesod.Static (Static (Static))
import Network.Wai.Application.Static (defaultFileServerSettings)
import Control.Monad (unless, forM_)
import Filesystem (isDirectory)
import System.Process (rawSystem)
import System.Exit (ExitCode (ExitSuccess), exitWith)
import System.Environment (getEnvironment)
import Control.Concurrent (forkIO)
import qualified Filesystem.Path.CurrentOS as F
import qualified Data.Text as T

-- Import all relevant handler modules here.
import Handler.Root
import Handler.Wiki
import Handler.Page
import Handler.Blog
import Handler.Book

instance YesodSubDispatch BookSub (HandlerT YesodWeb IO) where
    yesodSubDispatch = $(mkYesodSubDispatch resourcesBookSub)

-- This line actually creates our YesodSite instance. It is the second half
-- of the call to mkYesodData which occurs in Foundation.hs. Please see
-- the comments there for more details.
mkYesodDispatch "YesodWeb" resourcesYesodWeb

-- This function allocates resources (such as a database connection pool),
-- performs initialization and creates a WAI application. This is also the
-- place to put your migrate statements to have automatic database
-- migrations handled by Yesod.
getApplication :: AppConfig DefaultEnv Extra -> IO Application
getApplication conf = do
    env <- getEnvironment
    forM_ branches $ \(dir, branch) -> do
        exists <- isDirectory $ F.decodeString dir
        unless exists $ do
            putStrLn $ "Cloning " ++ dir
            ec <- rawSystem "git"
                [ "clone"
                , "-b"
                , branch
                , fromMaybe "https://github.com/yesodweb/yesodweb.com-content.git"
                  $ lookup "CONTENT_REPO" env
                , dir
                ]
            unless (ec == ExitSuccess) $ do
                putStrLn "git clone failed, exiting"
                exitWith ec

    s <- staticSite
    let assets = Static $ defaultFileServerSettings "content/static"

    mblog <- loadBlog
    iblog <- newIORef $ fromMaybe (error "Invalid posts.yaml") mblog
    booksub12 <- mkBookSub "Yesod Web Framework Book- Version 1.2 (beta)" "Note: This version of the book is not yet complete, only the first part of the book (the first 11 chapters) are guaranteed to be accurate" $ F.decodeString dirCurrent
    booksub11 <- mkBookSub "Yesod Web Framework Book- Version 1.1" "Note: You are looking at version 1.1 of the book, which is one version behind" $ F.decodeString dir11
    iauthors <- loadAuthors >>= newIORef

    let foundation = YesodWeb
            { settings = conf
            , getStatic = s
            , getAssets = assets
            , ywBlog = iblog
            , ywAuthors = iauthors
            , getBook12 = booksub12
            , getBook11 = booksub11
            }
    app <- toWaiAppPlain foundation
    logWare <- mkLogWare
    return $ gzip def
           $ autohead
           $ logWare
             app
  where
#ifdef DEVELOPMENT
    mkLogWare = return logStdoutDev
#else
    mkLogWare = mkRequestLogger def
        { outputFormat = Apache FromHeader
        }
#endif

mkBookSub :: Html -> Text -> F.FilePath -> IO BookSub
mkBookSub title warning root' = do
    Just branch <- return $ lookup (F.encodeString root') branches
    let root = root' F.</> "book"
    ibook <- newIORef $ error "Still loading"
    _ <- forkIO $ loadBook root >>= writeIORef ibook
    return BookSub
        { bsRoot = root
        , bsBook = ibook
        , bsReload = loadBook root >>= writeIORef ibook
        , bsTitle = title
        , bsWarning = if T.null warning then Nothing else Just (toHtml warning)
        , bsBranch = T.pack branch
        }

-- for yesod devel
getApplicationDev :: IO (Int, Application)
getApplicationDev =
    defaultDevelApp loader getApplication
  where
    loader = Yesod.Default.Config.loadConfig (configSettings Development)
        { csParseExtra = parseExtra
        }

dirCurrent :: FilePath
dirCurrent = "content"

dir11 :: FilePath
dir11 = "content-1.1"

branches :: [(FilePath, String)]
branches =
    [ (dirCurrent, "master")
    , (dir11, "version1.1")
    ]

postReloadR :: Handler ()
postReloadR = do
    yw <- getYesod
    _ <- liftIO $ forkIO $ do
        forM_ branches $ \(dir, branch) -> do
            let run x y = runProcess x y (Just dir) Nothing Nothing Nothing Nothing >>= waitForProcess >> return ()
            run "git" ["fetch"]
            run "git" ["checkout", "origin/" ++ branch]
        mblog <- loadBlog
        case mblog of
            Nothing -> return ()
            Just blog -> writeIORef (ywBlog yw) blog
        bsReload $ getBook12 yw
        bsReload $ getBook11 yw
        loadAuthors >>= writeIORef (ywAuthors yw)
    return ()
