module UpdateModuleName where

import "protolude" Protolude
import "text" Data.Text (Text)
import qualified "text" Data.Text as Text
import "non-empty-text" Data.NonEmptyText (NonEmptyText)
import qualified "non-empty-text" Data.NonEmptyText as NonEmptyText
import Text.Regex.Base
import Text.RE.PCRE.Text
import Data.String.QQ
import qualified Data.List as List
import qualified Data.List.NonEmpty as NonEmpty
import Options.Applicative
import Data.Char as Char
import ModuleName

startsWithModuleWord :: Text -> Bool
startsWithModuleWord line = case Protolude.head (Text.words line) of
  Nothing -> False
  Just h -> h == "module"

data UpdateModuleNameOutputError
  = UpdateModuleNameOutputError__ImpossibleErrorLineWithIndexNotFound
  | UpdateModuleNameOutputError__CannotParseModuleNameInsideOfFile Text
  deriving (Show, Eq)

data UpdateModuleNameOutput
  = UpdateModuleNameOutput__NothingChanged
  | UpdateModuleNameOutput__Error UpdateModuleNameOutputError
  | UpdateModuleNameOutput__Updated Text
  deriving (Show, Eq)

updateModuleName :: Text -> ModuleName -> UpdateModuleNameOutput
updateModuleName content expectedModuleName = do
  let contentLines = Text.lines content
  let lineWithModule :: Maybe Int = List.findIndex startsWithModuleWord contentLines

  let printedExpectedModuleName = printModuleName expectedModuleName

  case lineWithModule of
    Nothing -> UpdateModuleNameOutput__Updated $ Text.unlines
      [ "module " <> printedExpectedModuleName <> " where"
      , content
      ]
    Just index ->
      case List.splitAt index contentLines of
        (linesBeforeModule, moduleLine : linesAfterModule) ->
          case Text.words moduleLine of
            "module" : actualModuleName : moduleLineTail ->
              if actualModuleName == printedExpectedModuleName
                 then UpdateModuleNameOutput__NothingChanged
                 else UpdateModuleNameOutput__Updated . Text.unlines $ (linesBeforeModule <>
                    [ Text.unwords $ ["module", printedExpectedModuleName] <> moduleLineTail
                    ] <> linesAfterModule)
            _ -> UpdateModuleNameOutput__Error $ UpdateModuleNameOutputError__CannotParseModuleNameInsideOfFile moduleLine
        _ -> UpdateModuleNameOutput__Error UpdateModuleNameOutputError__ImpossibleErrorLineWithIndexNotFound
