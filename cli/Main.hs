{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE PackageImports #-}

module Main where

-- TODO: use http://hackage.haskell.org/package/managed instead of turtle

-- TODO
-- dont use system-filepath (Filesystem.Path module, good lib, turtle is using it,         FilePath is just record)
-- dont use filepath        (System.FilePath module, bad lib,  directory-tree is using it, FilePath is just String)
-- use https://hackage.haskell.org/package/path-io-1.6.0/docs/Path-IO.html walkDirAccumRel

-- TODO
-- use https://hackage.haskell.org/package/recursion-schemes

-- import qualified Filesystem.Path.CurrentOS
import Options.Applicative
import Options.Applicative.NonEmpty
import "protolude" Protolude hiding (find)
import qualified "turtle" Turtle
import "turtle" Turtle ((</>))
import qualified "directory" System.Directory
import qualified "filepath" System.FilePath
import qualified "system-filepath" Filesystem.Path
import "base" Data.String (String)
import qualified "base" Data.String as String
import qualified "base" Data.List as List
import qualified Data.List.Index as List
import qualified "text" Data.Text as Text
import qualified Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import qualified "directory-tree" System.Directory.Tree
import "directory-tree" System.Directory.Tree (DirTree (..), AnchoredDirTree (..))
import qualified "cases" Cases
import Control.Concurrent.Async
import UpdateModuleName
import Control.Monad.Writer

filterDirTreeByFilename :: (String -> Bool) -> DirTree a -> Bool
filterDirTreeByFilename _ (Dir ('.':_) _) = False
filterDirTreeByFilename pred (File n _) = pred n
filterDirTreeByFilename _ _ = True

dirTreeContent :: DirTree a -> IO [a]
dirTreeContent (Failed name err) = Turtle.die $ "Dir tree error: filename " <> show name <> ", error " <> show err
dirTreeContent (File fileName a) = pure [a]
dirTreeContent (Dir dirName contents) = do
  output :: [[a]] <- traverse dirTreeContent contents
  pure $ join output

anyCaseToCamelCase :: Text -> Text
anyCaseToCamelCase = Cases.process Cases.title Cases.camel -- first letter is always upper

data AppOptions = AppOptions
  { directories :: NonEmpty Turtle.FilePath
  }

appOptionsParser :: Parser AppOptions
appOptionsParser = AppOptions
  <$> some1
    ( fmap makeValidDirectory $ strOption
        ( long "directory"
      <> short 'd'
      <> metavar "DIRECTORY"
      <> help "Base dir with .purs files. Can pass multiple -d" )
    )

appOptionsParserInfo :: ParserInfo AppOptions
appOptionsParserInfo = info (appOptionsParser <**> helper)
  ( fullDesc
  <> progDesc "Adds or updates `module Foo.Bar` based on path"
  <> header "Update module name in directory recursively" )

-- Example:
-- baseDir - /home/srghma/projects/purescript-halogen-nextjs/app/
-- filePath - /home/srghma/projects/purescript-halogen-nextjs/app/Nextjs/Pages/Buttons/purs.purs
-- output - ["Nextjs","Pages","Buttons","purs"]
fullPathToPathToModule :: Turtle.FilePath -> Turtle.FilePath -> IO PathToModule
fullPathToPathToModule baseDir fullPath = do
  fullPath'' :: Turtle.FilePath <- maybe (Turtle.die $ "Cannot strip baseDir " <> show baseDir <> " from path " <> show fullPath) pure $ Turtle.stripPrefix baseDir fullPath
  let modulePathWithoutRoot :: [Text] = fmap (toS . stripSuffix "/" . Turtle.encodeString) . Turtle.splitDirectories . Filesystem.Path.dropExtensions $ fullPath''

  modulePathWithoutRoot' :: NonEmpty Text <- maybe (Turtle.die $ "should be nonEmpty modulePathWithoutRoot for" <> show baseDir <> " from path " <> show fullPath) pure $ NonEmpty.nonEmpty modulePathWithoutRoot

  pure (PathToModule modulePathWithoutRoot')

appendIfNotAlreadySuffix :: Eq a => [a] -> [a] -> [a]
appendIfNotAlreadySuffix suffix target =
  if List.isSuffixOf suffix target
     then target
     else target ++ suffix

stripSuffix :: Eq a => [a] -> [a] -> [a]
stripSuffix suffix target =
  if List.isSuffixOf suffix target
     then List.reverse $ List.drop (List.length suffix) $ List.reverse target
     else target

-- make it end with /
makeValidDirectory :: Turtle.FilePath -> Turtle.FilePath
makeValidDirectory = Turtle.decodeString . appendIfNotAlreadySuffix "/" . Turtle.encodeString

withConcurrentPutStrLn f = do
  mutex <- newMVar ()

  let putStrLn' = withMVar mutex . const . putStrLn @Text

  f putStrLn'

findPursFiles :: Turtle.FilePath -> IO [Turtle.FilePath]
findPursFiles baseDir = do
  -- contains absolute path inside
  _base :/ (dirTree :: DirTree FilePath) <- System.Directory.Tree.readDirectoryWith return (Turtle.encodeString baseDir)

  let (dirTreeWithPursFiles :: DirTree FilePath) =
        System.Directory.Tree.filterDir
          (filterDirTreeByFilename (\n -> System.FilePath.takeExtensions n == ".purs"))
          dirTree

  filePaths :: [Turtle.FilePath] <- map Turtle.decodeString <$> dirTreeContent dirTreeWithPursFiles

  pure filePaths

main :: IO ()
main = do
  appOptions <- execParser appOptionsParserInfo

  baseDirsWithPursFiles :: NonEmpty (Turtle.FilePath, [Turtle.FilePath]) <-
    forConcurrently (directories appOptions) \baseDir -> do
      files <- findPursFiles baseDir
      pure $ (baseDir, files)

  -- putStrLn $ "baseDir " <> Turtle.encodeString baseDir

  withConcurrentPutStrLn \concurrentPutStrLn ->
    forConcurrently_ baseDirsWithPursFiles \((baseDir, filePaths)) ->
      forConcurrently_ filePaths \filePath -> do
        let
          log x = tell [x]

          action :: WriterT [Text] IO ()
          action = do
            log $ toS $ "processing " <> Turtle.encodeString filePath

            fileContent <- liftIO $ Turtle.readTextFile filePath

            pathToModule <- liftIO $ fullPathToPathToModule baseDir filePath

            case updateModuleName fileContent pathToModule of
              UpdateModuleNameOutput__NothingChanged -> log $ "  nothing changed"
              UpdateModuleNameOutput__Error errorMessage -> log $ "  error: " <> errorMessage
              UpdateModuleNameOutput__Updated newFileContent -> do
                liftIO $ Turtle.writeTextFile filePath newFileContent
                log $ "  updated module name to \"" <> printPathToModule pathToModule <> "\""

        execWriterT action >>= (concurrentPutStrLn . Text.intercalate "\n")
