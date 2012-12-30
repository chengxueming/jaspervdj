--------------------------------------------------------------------------------
{-# LANGUAGE Arrows            #-}
{-# LANGUAGE OverloadedStrings #-}
module Main where


--------------------------------------------------------------------------------
import           Control.Applicative ((<$>))
import qualified Data.ByteString     as B
import           Data.Monoid         (mappend, mconcat)
import           Prelude             hiding (id)
import           System.Cmd          (system)
import           System.Directory    (getTemporaryDirectory)
import           System.FilePath     (takeFileName, (<.>), (</>))
import qualified Text.Pandoc         as Pandoc


--------------------------------------------------------------------------------
import           Hakyll


--------------------------------------------------------------------------------
-- | Entry point
main :: IO ()
main = hakyllWith config $ do
    -- Copy images
    match "images/*" $ do
        route idRoute
        compile copyFileCompiler

    match "favicon.ico" $ do
        route   idRoute
        compile copyFileCompiler

    -- Copy files (deep)
    match "files/**" $ do
        route idRoute
        compile copyFileCompiler

    -- Compress CSS
    match "css/*" $ do
        route idRoute
        compile compressCssCompiler

    -- Render the /tmp index page
    match "tmp/index.html" $ do
        route idRoute
        compile $ getResourceBody >>= relativizeUrls

    -- Build tags
    tags <- buildTags "posts/*" (fromCapture "tags/*.html")

    -- Render each and every post
    match "posts/*" $ do
        route   $ setExtension ".html"
        compile $ do
            pandocCompiler
                >>= saveSnapshot "content"
                >>= return . fmap demoteHeaders
                >>= loadAndApplyTemplate "templates/post.html" (postCtx tags)
                >>= loadAndApplyTemplate "templates/default.html" defaultContext
                >>= relativizeUrls

    -- Post list
    match "posts.html" $ do
        route idRoute
        compile $ do
            list <- postList tags "posts/*" recentFirst
            makeItem ""
                >>= loadAndApplyTemplate "templates/posts.html"
                        (constField "title" "Posts" `mappend`
                            constField "posts" list `mappend`
                            defaultContext)
                >>= loadAndApplyTemplate "templates/default.html" defaultContext
                >>= relativizeUrls

    -- Post tags
    tagsRules tags $ \tag pattern -> do
        let title = "Posts tagged " ++ tag

        -- Copied from posts, need to refactor
        route idRoute
        compile $ do
            list <- postList tags pattern recentFirst
            makeItem ""
                >>= loadAndApplyTemplate "templates/posts.html"
                        (constField "title" title `mappend`
                            constField "posts" list `mappend`
                            defaultContext)
                >>= loadAndApplyTemplate "templates/default.html" defaultContext
                >>= relativizeUrls

        -- Create RSS feed as well
        version "rss" $ do
            route   $ setExtension "xml"
            compile $ loadAllSnapshots pattern "content"
                >>= return . take 10 . recentFirst
                >>= renderAtom (feedConfiguration title) feedCtx

    -- Index
    match "index.html" $ do
        route idRoute
        compile $ do
            list <- postList tags "posts/*" $ take 3 . recentFirst
            let indexContext = constField "posts" list `mappend`
                    field "tags" (\_ -> renderTagList tags) `mappend`
                    defaultContext

            getResourceBody
                >>= applyAsTemplate indexContext
                >>= loadAndApplyTemplate "templates/default.html" indexContext
                >>= relativizeUrls

    -- Read templates
    match "templates/*" $ compile $ templateCompiler

    -- Render some static pages
    match (fromList pages) $ do
        route   $ setExtension ".html"
        compile $ pandocCompiler
            >>= loadAndApplyTemplate "templates/default.html" defaultContext
            >>= relativizeUrls

    -- Render the 404 page, we don't relativize URL's here.
    match "404.html" $ do
        route idRoute
        compile $ pandocCompiler
            >>= loadAndApplyTemplate "templates/default.html" defaultContext

    -- Render RSS feed
    match "rss.xml" $ do
        route idRoute
        compile $ do
            loadAllSnapshots "posts/*" "content"
                >>= return . take 10 . recentFirst
                >>= renderAtom (feedConfiguration "All posts") feedCtx

    -- CV as HTML
    match "cv.markdown" $ do
        route   $ setExtension ".html"
        compile $ do
            cvTpl      <- loadBody "templates/cv.html"
            defaultTpl <- loadBody "templates/default.html"
            pandocCompiler
                >>= applyTemplate cvTpl defaultContext
                >>= applyTemplate defaultTpl defaultContext
                >>= relativizeUrls

    -- CV as PDF
    match "cv.markdown" $ version "pdf" $ do
        route   $ setExtension ".pdf"
        compile $ do
            cvTpl <- loadBody "templates/cv.tex"
            getResourceBody
                >>= (return . readPandoc)
                >>= (return .
                     fmap (Pandoc.writeLaTeX Pandoc.defaultWriterOptions))
                >>= applyTemplate cvTpl defaultContext
                >>= pdflatex
  where
    pages =
        [ "contact.markdown"
        , "links.markdown"
        , "recommendations.markdown"
        ]


--------------------------------------------------------------------------------
postCtx :: Tags -> Context String
postCtx tags = mconcat
    [ modificationTimeField "mtime" "%U"
    , dateField "date" "%B %e, %Y"
    , tagsField "tags" tags
    , defaultContext
    ]


--------------------------------------------------------------------------------
feedCtx :: Context String
feedCtx = mconcat
    [ bodyField "description"
    , defaultContext
    ]


--------------------------------------------------------------------------------
config :: Configuration
config = defaultConfiguration
    { deployCommand = "rsync --checksum -ave 'ssh -p 2222' \
                      \_site/* jaspervdj@jaspervdj.be:jaspervdj.be"
    , verbosity = Debug
    }


--------------------------------------------------------------------------------
feedConfiguration :: String -> FeedConfiguration
feedConfiguration title = FeedConfiguration
    { feedTitle       = "jaspervdj - " ++ title
    , feedDescription = "Personal blog of jaspervdj"
    , feedAuthorName  = "Jasper Van der Jeugt"
    , feedAuthorEmail = "jaspervdj@gmail.com"
    , feedRoot        = "http://jaspervdj.be"
    }


--------------------------------------------------------------------------------
postList :: Tags -> Pattern -> ([Item String] -> [Item String])
         -> Compiler String
postList tags pattern preprocess = do
    postItemTpl <- loadBody "templates/postitem.html"
    posts       <- preprocess <$> loadAll pattern
    applyTemplateList postItemTpl (postCtx tags) posts


--------------------------------------------------------------------------------
-- | Hacky.
pdflatex :: Item String -> Compiler (Item B.ByteString)
pdflatex item = unsafeCompiler $ do
    tmpDir <- getTemporaryDirectory
    let name = takeFileName $ toFilePath $ itemIdentifier item
        tex  = tmpDir </> name <.> "tex"
        pdf  = tmpDir </> name <.> "pdf"

    writeFile tex $ itemBody item
    _ <- system $ unwords ["pdflatex",
        "-output-directory", tmpDir, tex, ">/dev/null", "2>&1"]
    body <- B.readFile pdf
    return $ itemSetBody body item
