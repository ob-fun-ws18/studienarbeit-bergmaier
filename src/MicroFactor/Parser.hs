module MicroFactor.Parser
    ( ParsedRef (..)
    , ResolvedRef (..)
    , expressionParser
    , Command (..)
    , resolveNames
    , builtinSymbols
    , commandParser
    , resolve
    ) where

import Data.Monoid ((<>))
import Control.Monad
import Control.Arrow (second)
import Control.Applicative ((<|>))
import Data.Functor (($>), (<&>))
import Data.Char (digitToInt)
import Data.Map.Strict (Map, fromList, lookup)
import Text.Parsec.String (Parser)
import Text.Parsec hiding ((<|>))
import Prelude hiding (lookup)

import MicroFactor.Data

--------------------------------------------------------------------------------

data ParsedRef
    = Anonymous [MicroFactorInstruction ParsedRef]
    | Named SourcePos String
    deriving (Eq, Show)

instance InstructionRef ParsedRef where
    makeRef = Anonymous
    resolveRef = const [] -- TODO

data ResolvedRef = ResolvedRef String [MicroFactorInstruction ResolvedRef]

instance InstructionRef ResolvedRef where
    makeRef = ResolvedRef ""
    resolveRef (ResolvedRef _ is) = is

instance Show ResolvedRef where
    -- avoid showing circular structures in recursive functions
    show (ResolvedRef name _) = "ResolvedRef { " ++ name ++ " }"

--------------------------------------------------------------------------------

expressionParser :: Parser [MicroFactorInstruction ParsedRef]
expressionParser = element `sepBy1` spaces -- TODO: require at least 1 space?
  where
    element = choice
        [ parenthised
        , numberLiteral
        , stringLiteral
        , Wrapper <$> (char '\'' *> identifier)
        , identifier
        ]
    identifier = Call <$> liftM2 Named getPosition identifierParser
    parenthised = flip labels ["comment", "block"] $ do
        end <- choice [char a $> b | (a, b) <- [('(',')'), ('[',']'), ('{','}')]]
        choice
            [ Comment <$> do
                delim <- oneOf "#-*"
                spaces
                manyTill anyChar $ try $ spaces >> char delim >> char end
            , Wrapper . Call . Anonymous <$> (spaces *> expressionParser <* spaces <* char end)
            ]
    numberLiteral = flip label "number" $ (char '0' >> choice
        [ char 'x' >> many1 hexDigit <&> parseNumber 16
        , char 'b' >> many1 (oneOf "01") <&> parseNumber 2
        , many digit <&> parseNumber 10
        ]) <|> (many1 digit <&> parseNumber 10)
    parseNumber base = LiteralValue . foldl (\x -> ((base * x) +) . fromIntegral . digitToInt) 0
    stringLiteral = flip label "string" $ do
        delim <- many1 $ char '"'
        LiteralString <$> manyTill ((char '\\' >> choice
            [ char 'r' $> '\r'
            , char 'n' $> '\n'
            , char 't' $> '\t'
            , anyChar
            ]) <|> anyChar) (try $ string delim)

identifierParser :: Parser String
identifierParser = flip label "identifier" $ many1 $ noneOf " ()[]{}'\":;"

--------------------------------------------------------------------------------

data Command
    = Quit
    | Define String [MicroFactorInstruction ParsedRef]
    | Evaluate [MicroFactorInstruction ParsedRef]
    | ShowDef String

commandParser :: Parser [Command]
commandParser = choice
    [ do
        char ':'
        id <- identifierParser
        spaces
        expr <- expressionParser
        char ';'
        return $ Define id expr
    , Quit <$ string "Quit"
    , ShowDef <$> (string "Show" *> many1 space *> identifierParser)
    , Evaluate <$> expressionParser <?> "expression"
    ] `sepBy` spaces <* eof

--------------------------------------------------------------------------------

resolveNames :: (a -> Either b (MicroFactorInstruction c)) -> [MicroFactorInstruction a] -> Either b [MicroFactorInstruction c]
resolveNames f = fmap (fmap join) . traverse (traverse f)

builtinSymbols :: Map String (MicroFactorInstruction a)
builtinSymbols = fromList $ fmap (second Operator)
    [ ("nor",      LogicNor)
    --, ("-!>",      LogicInhib)
    , ("xor",      LogicXor)
    , ("nand",     LogicNand)
    , ("xnor",     LogicXnor)
    , ("->",       LogicLte)
    , (">=",       LogicGte)
    , ("<=",       LogicLte)
    , ("not",      LogicNot)
    --, ("rand",     RANDOM)
    , ("*",        ArithMul)
    , ("+",        ArithAdd)
    , ("-",        ArithSub)
    , (".",        Send)
    , ("/",        ArithDiv)
    , ("/mod",     ArithDivmod)
    , ("<",        LogicLt)
    , ("=",        LogicXnor)
    , (">",        LogicGt)
    , ("abs",      ArithAbs)
    , ("and",      LogicAnd)
    , ("drop",     StackDrop)
    , ("dup",      StackDuplicate)
    , ("execute",  Execute)
    , ("max",      ArithMax)
    , ("min",      ArithMin)
    , ("mod",      ArithMin)
    , ("or",       LogicOr)
    , ("over",     StackOver)
    , ("rot",      StackRotate)
    , ("swap",     StackSwap)
    , ("<>",       LogicXor)
    , ("nip",      StackNip)
    , ("false",    LiteralFalse)
    , ("true",     LiteralTrue)
    , ("pick",     StackPick)
    , ("roll",     StackRoll)
    , ("tuck",     StackTuck)
    , ("debugger", Debugger)
    ]

resolve :: Map String [MicroFactorInstruction ResolvedRef] -> [MicroFactorInstruction ParsedRef] -> Either (SourcePos, String) [MicroFactorInstruction ResolvedRef]
resolve userDefs = resolveNames go
  where
    go :: ParsedRef -> Either (SourcePos, String) (MicroFactorInstruction ResolvedRef)
    go (Anonymous is) = fmap (Call . ResolvedRef "") (resolveNames go is)
    go (Named loc name) = maybe (Left (loc, name)) Right $
        lookup name builtinSymbols <|> fmap (Call . ResolvedRef name) (lookup name userDefs)
