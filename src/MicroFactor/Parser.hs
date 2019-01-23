module MicroFactor.Parser
    ( ParsedRef (..)
    , ResolvedRef (..)
    , expressionParser
    , Command (..)
    , resolveNames
    , builtinSymbols
    , commandParser
    , resolve
    , formatErrorMessages
    ) where

import Control.Monad
import Control.Applicative ((<|>))
import Data.Functor (($>), (<&>))
import Data.Char (digitToInt)
import Data.Map.Strict (Map, fromList, lookup)
import Text.Parsec hiding ((<|>))
import Text.Parsec.String (Parser)
import Text.Parsec.Error
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
    refName (Anonymous _) = ""
    refName (Named _ n) = n

data ResolvedRef = ResolvedRef String [MicroFactorInstruction ResolvedRef] deriving Eq

instance InstructionRef ResolvedRef where
    makeRef = ResolvedRef ""
    resolveRef (ResolvedRef _ is) = is
    refName (ResolvedRef n _) = n

instance Show ResolvedRef where
    -- avoid showing circular structures in recursive functions
    show (ResolvedRef "" is) = "(" ++ show is ++ ")"
    show (ResolvedRef name _) = name

--------------------------------------------------------------------------------

expressionParser :: Parser [MicroFactorInstruction ParsedRef]
expressionParser = element `sepBy1` spaces
  where
    element = choice
        [ parenthised
        , numberLiteral
        , stringLiteral
        , Literal . Instruction <$> (char '\'' *> identifier)
        , identifier
        ] <?> "expression item"
    identifier = Call <$> liftM2 Named getPosition identifierParser
    parenthised = flip labels ["comment", "block"] do
        end <- choice [char a $> b | (a, b) <- [('(',')'), ('[',']'), ('{','}')]]
        choice
            [ Comment <$> do
                delim <- oneOf "#-*"
                spaces
                manyTill anyChar $ try $ spaces >> char delim >> char end
            , Literal . Instruction . Call . Anonymous <$> (spaces *> element `sepEndBy1` spaces <* char end)
            ]
    numberLiteral = flip label "number" $ (char '0' >> choice
        [ char 'x' >> many1 hexDigit <&> parseNumber 16
        , char 'b' >> many1 (oneOf "01") <&> parseNumber 2
        , many digit <&> parseNumber 10
        ]) <|> (many1 digit <&> parseNumber 10)
    parseNumber base = Literal . Integer . foldl (\x -> ((base * x) +) . fromIntegral . digitToInt) 0
    stringLiteral = flip label "string" do
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
    | List
    | Define String [MicroFactorInstruction ParsedRef]
    | Evaluate [MicroFactorInstruction ParsedRef]
    | ShowDef String
    deriving (Eq, Show)

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
    , List <$ string "List"
    , ShowDef <$> (string "Show" *> many1 space *> identifierParser)
    , Evaluate <$> expressionParser <?> "expression"
    ] `sepBy` spaces <* eof

--------------------------------------------------------------------------------

resolveNames :: (a -> Either b (MicroFactorInstruction c)) -> [MicroFactorInstruction a] -> Either b [MicroFactorInstruction c]
resolveNames f = fmap (fmap join) . traverse (traverse f)

builtinSymbols :: InstructionRef r => Map String (MicroFactorInstruction r)
builtinSymbols = fromList $ fmap (show >>= (,)) $ fmap Operator [minBound..maxBound] ++ fmap (Literal . Boolean) [True, False]

resolve :: Map String [MicroFactorInstruction ResolvedRef] -> [MicroFactorInstruction ParsedRef] -> Either ParseError [MicroFactorInstruction ResolvedRef]
resolve userDefs = resolveNames go
  where
    go :: ParsedRef -> Either ParseError (MicroFactorInstruction ResolvedRef)
    go (Anonymous is) = fmap (Call . ResolvedRef "") (resolveNames go is)
    go (Named loc name) = maybe (Left $ newErrorMessage (Message $ "unknown identifier " ++ name) loc) Right $
        lookup name builtinSymbols <|> fmap (Call . ResolvedRef name) (lookup name userDefs)

formatErrorMessages :: ParseError -> String
formatErrorMessages = showErrorMessages "or" "oops?" "expecting" "unexpected" "end of input" . errorMessages