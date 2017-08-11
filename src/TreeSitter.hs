{-# LANGUAGE DataKinds, ScopedTypeVariables, TypeOperators #-}
module TreeSitter
( treeSitterParser
, parseToAST
, defaultTermAssignment
) where

import Category
import Control.Comonad (extract)
import Control.Exception
import Control.Monad ((<=<))
import Data.Blob
import Data.ByteString.Unsafe (unsafeUseAsCStringLen)
import Data.Functor.Foldable hiding (Nil)
import Data.Range
import Data.Record
import Data.Source
import Data.Span
import qualified Data.Syntax.Assignment as A
import Data.Text (Text, pack)
import Language
import qualified Language.Go as Go
import qualified Language.TypeScript as TS
import qualified Language.Ruby as Ruby
import Foreign
import Foreign.C.String (peekCString)
import Foreign.Marshal.Array (allocaArray)
import qualified Syntax as S
import Term
import qualified TreeSitter.Document as TS
import qualified TreeSitter.Node as TS
import qualified TreeSitter.Language as TS
import qualified TreeSitter.Go as TS
import qualified TreeSitter.Ruby as TS
import qualified TreeSitter.TypeScript as TS
import Info

-- | Returns a TreeSitter parser for the given language and TreeSitter grammar.
treeSitterParser :: Ptr TS.Language -> Blob -> IO (SyntaxTerm DefaultFields)
treeSitterParser language blob = bracket TS.ts_document_new TS.ts_document_free $ \ document -> do
  TS.ts_document_set_language document language
  unsafeUseAsCStringLen (sourceBytes (blobSource blob)) $ \ (sourceBytes, len) -> do
    TS.ts_document_set_input_string_with_length document sourceBytes len
    TS.ts_document_parse_halt_on_error document
    term <- documentToTerm language document blob
    pure term


-- | Parse 'Source' with the given 'TS.Language' and return its AST.
parseToAST :: (Bounded grammar, Enum grammar) => Ptr TS.Language -> Blob -> IO (A.AST grammar)
parseToAST language Blob{..} = bracket TS.ts_document_new TS.ts_document_free $ \ document -> do
  TS.ts_document_set_language document language
  root <- unsafeUseAsCStringLen (sourceBytes blobSource) $ \ (source, len) -> do
    TS.ts_document_set_input_string_with_length document source len
    TS.ts_document_parse_halt_on_error document
    alloca (\ rootPtr -> do
      TS.ts_document_root_node_p document rootPtr
      peek rootPtr)

  anaM toAST root

toAST :: forall grammar . (Bounded grammar, Enum grammar) => Node -> IO (Base (A.AST grammar) Node)
toAST node@TS.Node{..} = do
  let count = fromIntegral nodeChildCount
  children <- allocaArray count $ \ childNodesPtr -> do
    _ <- with nodeTSNode (\ nodePtr -> TS.ts_node_copy_child_nodes nullPtr nodePtr childNodesPtr (fromIntegral count))
    peekArray count childNodesPtr
  pure $! A.Node (toEnum (min (fromIntegral nodeSymbol) (fromEnum (maxBound :: grammar)))) (nodeRange node) (nodeSpan node) :< children

anaM :: (Corecursive t, Monad m, Traversable (Base t)) => (a -> m (Base t a)) -> a -> m t
anaM g = a where a = pure . embed <=< traverse a <=< g


-- | Return a parser for a tree sitter language & document.
documentToTerm :: Ptr TS.Language -> Ptr Document -> Blob -> IO (SyntaxTerm DefaultFields)
documentToTerm language document Blob{..} = do
  root <- alloca (\ rootPtr -> do
    TS.ts_document_root_node_p document rootPtr
    peek rootPtr)
  toTerm root
  where toTerm :: Node -> IO (SyntaxTerm DefaultFields)
        toTerm node@TS.Node{..} = do
          name <- peekCString nodeType

          children <- getChildren (fromIntegral nodeNamedChildCount) copyNamed
          let allChildren = getChildren (fromIntegral nodeChildCount) copyAll

          let source = slice (nodeRange node) blobSource
          assignTerm language source (range :. categoryForLanguageProductionName language (pack name) :. nodeSpan node :. Nil) children allChildren
          where getChildren count copy = do
                  nodes <- allocaArray count $ \ childNodesPtr -> do
                    _ <- with nodeTSNode (\ nodePtr -> copy nodePtr childNodesPtr (fromIntegral count))
                    peekArray count childNodesPtr
                  children <- traverse toTerm nodes
                  return $! filter isNonEmpty children
                range = nodeRange node
        copyNamed = TS.ts_node_copy_named_child_nodes document
        copyAll = TS.ts_node_copy_child_nodes document

isNonEmpty :: HasField fields Category => SyntaxTerm fields -> Bool
isNonEmpty = (/= Empty) . category . extract

nodeRange :: TS.Node -> Range
nodeRange TS.Node{..} = Range (fromIntegral nodeStartByte) (fromIntegral nodeEndByte)

nodeSpan :: TS.Node -> Span
nodeSpan TS.Node{..} = nodeStartPoint `seq` nodeEndPoint `seq` Span (pointPos nodeStartPoint) (pointPos nodeEndPoint)
  where pointPos TS.TSPoint{..} = pointRow `seq` pointColumn `seq` Pos (1 + fromIntegral pointRow) (1 + fromIntegral pointColumn)

assignTerm :: Ptr TS.Language -> Source -> Record DefaultFields -> [ SyntaxTerm DefaultFields ] -> IO [ SyntaxTerm DefaultFields ] -> IO (SyntaxTerm DefaultFields)
assignTerm language source annotation children allChildren =
  cofree . (annotation :<) <$> case assignTermByLanguage source (category annotation) children of
    Just a -> pure a
    _ -> defaultTermAssignment source (category annotation) children allChildren
  where assignTermByLanguage :: Source -> Category -> [ SyntaxTerm DefaultFields ] -> Maybe (S.Syntax (SyntaxTerm DefaultFields))
        assignTermByLanguage = case languageForTSLanguage language of
          Just Language.Go -> Go.termAssignment
          Just Ruby -> Ruby.termAssignment
          Just TypeScript -> TS.termAssignment
          _ -> \ _ _ _ -> Nothing

defaultTermAssignment :: Source -> Category -> [ SyntaxTerm DefaultFields ] -> IO [ SyntaxTerm DefaultFields ] -> IO (S.Syntax (SyntaxTerm DefaultFields))
defaultTermAssignment source category children allChildren
  | category `elem` operatorCategories = S.Operator <$> allChildren
  | otherwise = pure $! case (category, children) of
    (ParseError, children) -> S.ParseError children

    (Comment, _) -> S.Comment (toText source)

    (Pair, [key, value]) -> S.Pair key value

    -- Control flow statements
    (If, condition : body) -> S.If condition body
    (Switch, _) -> uncurry S.Switch (break ((== Case) . Info.category . extract) children)
    (Case, expr : body) -> S.Case expr body
    (While, expr : rest) -> S.While expr rest

    -- Statements
    (Return, _) -> S.Return children
    (Yield, _) -> S.Yield children
    (Throw, [expr]) -> S.Throw expr
    (Break, [label]) -> S.Break (Just label)
    (Break, []) -> S.Break Nothing
    (Continue, [label]) -> S.Continue (Just label)
    (Continue, []) -> S.Continue Nothing

    (_, []) -> S.Leaf (toText source)
    (_, children) -> S.Indexed children
  where operatorCategories =
          [ Operator
          , Binary
          , Unary
          , RangeExpression
          , ScopeOperator
          , BooleanOperator
          , MathOperator
          , RelationalOperator
          , BitwiseOperator
          ]


categoryForLanguageProductionName :: Ptr TS.Language -> Text -> Category
categoryForLanguageProductionName = withDefaults . byLanguage
  where
    withDefaults productionMap name = case name of
      "ERROR" -> ParseError
      s -> productionMap s

    byLanguage language = case languageForTSLanguage language of
      Just Ruby -> Ruby.categoryForRubyName
      Just Language.Go -> Go.categoryForGoName
      Just TypeScript -> TS.categoryForTypeScriptName
      _ -> Other


languageForTSLanguage :: Ptr TS.Language -> Maybe Language
languageForTSLanguage = flip lookup
  [ (TS.tree_sitter_go, Language.Go)
  , (TS.tree_sitter_ruby, Ruby)
  , (TS.tree_sitter_typescript, TypeScript)
  ]
