{- Expands template haskell splices
 -
 - First, the code must be built with a ghc that supports TH,
 - and the splices dumped to a log. For example:
 -   cabal build --ghc-options=-ddump-splices 2>&1 | tee log
 -
 - Along with the log, a "headers" file may also be provided, containing
 - additional imports needed by the template haskell code.
 -
 - This program will parse the log, and expand all splices therein,
 - modifying files in the source tree. They can then be built a second
 - time, with a ghc that does not support TH.
 -
 - Note that template haskell code may refer to symbols that are not
 - exported by the library that defines the TH code. In this case,
 - the library has to be modifed to export those symbols.
 -
 - There can also be other problems with the generated code; it may
 - need modifications to compile.
 -
 -
 - Copyright 2013 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

import Text.Parsec
import Text.Parsec.String
import Control.Applicative ((<$>))
import Data.Either
import Data.List
import Data.String.Utils
import Data.Char

import Utility.Monad
import Utility.Misc
import Utility.Exception

data Coord = Coord
	{ coordLine :: Int
	, coordColumn :: Int
	}
	deriving (Read, Show)

offsetCoord :: Coord -> Coord -> Coord
offsetCoord a b = Coord
	(coordLine a - coordLine b)
	(coordColumn a - coordColumn b)

data Splice = Splice
	{ splicedFile :: FilePath
	, spliceStart :: Coord
	, spliceEnd :: Coord
	, splicedExpression :: String
	, splicedResult :: String
	}
	deriving (Read, Show)

number :: Parser Int
number = read <$> many1 digit

{- A pair of Coords is written in one of two ways:
 - "95:21-73" or "(92,25)-(94,2)"
 -}
coordsParser :: Parser (Coord, Coord)
coordsParser = (singleline <|> multiline) <?> "Coords"
  where
  	singleline = do
		line <- number
		char ':'
		startcol <- number
		char '-'
		endcol <- number
		return $ (Coord line startcol, Coord line endcol)

	multiline = do
		start <- fromparens
		char '-'
		end <- fromparens
		return $ (start, end)

	fromparens = between (char '(') (char ')') $ do
		line <- number
		char ','
		col <- number
		return $ Coord line col

indent :: Parser String
indent = many1 $ char ' '

restOfLine :: Parser String
restOfLine = newline `after` many (noneOf "\n")

indentedLine :: Parser String
indentedLine = indent >> restOfLine

spliceParser :: Parser Splice
spliceParser = do
	file <- many1 (noneOf ":\n")
	char ':'
	(start, end) <- coordsParser
	string ": Splicing expression"
	newline

	expression <- indentedLine

	indent
	string "======>"	
	newline

	{- All lines of the splice result will start with the same
	 - indent, which is stripped. Any other indentation is preserved. -}
	i <- lookAhead indent
	result <- unlines <$> many1 (string i >> restOfLine)

	return $ Splice file start end expression result

{- Extracts the splices, ignoring the rest of the compiler output. -}
splicesExtractor :: Parser [Splice]
splicesExtractor = rights <$> many extract
  where
  	extract = try (Right <$> spliceParser) <|> (Left <$> compilerJunkLine)
	compilerJunkLine = restOfLine

{- Modifies the source file, expanding the splices, which all must
 - have the same splicedFile.
 -
 - Each splice's Coords refer to the original position in the file,
 - and not to its position after any previous splices may have inserted
 - or removed lines.
 -
 - To deal with this complication, the file is broken into logical lines
 - (which can contain any String, including a multiline or empty string).
 - Each splice is assumed to be on its own block of lines; two
 - splices on the same line is not currently supported.
 - This means that a splice can modify the logical lines within its block
 - as it likes, without interfering with the Coords of other splices.
 - 
 - As well as expanding splices, this can add a block of imports to the
 - file. These are put right before the first line in the file that
 - starts with "import "
 -}
applySplices :: Maybe String -> [Splice] -> IO ()
applySplices imports l@(first:_) = do
	let f = splicedFile first
	lls <- map (++ "\n") . lines <$> readFileStrict f
	writeFile f $ concat $ addimports $ expand lls l
  where
  	expand lls [] = lls
  	expand lls (s:rest) = expand (expandSplice s lls) rest

	addimports lls = case imports of
		Nothing -> lls
		Just v ->
			let (start, end) = break ("import " `isPrefixOf`) lls
			in if null end
				then start
				else concat
					[ start
					, [v]
					, end
					]

expandSplice :: Splice -> [String] -> [String]
expandSplice s lls = concat [before, new:splicerest, end]
  where
	cs = spliceStart s
	ce = spliceEnd s

	(before, rest) = splitAt (coordLine cs - 1) lls
	(oldlines, end) = splitAt (1 + coordLine (offsetCoord ce cs)) rest
	(splicestart, splicerest) = case oldlines of
		l:r -> (expandtabs l, take (length r) (repeat []))
		_ -> ([], [])
	new = concat
		[ let s = deqqstart $ take (coordColumn cs - 1) splicestart
		  in if all isSpace s
		  	then ""
			else s
		, addindent (findindent splicestart) (mangleCode $ splicedResult s)
		, deqqend $ drop (coordColumn ce) splicestart
		]

	{- coordinates assume tabs are expanded to 8 spaces -}
	expandtabs = replace "\t" (take 8 $ repeat ' ')

	{- splicing leaves $() quasiquote behind; remove it -}
	deqqstart s = case reverse s of
		('(':'$':rest) -> reverse rest
		_ -> s
	deqqend (')':s) = s
	deqqend s = s

	findindent = length . takeWhile isSpace
	addindent n = unlines . map (i ++) . lines
	  where
	  	i = take n $ repeat ' '

{- Tweaks code output by GHC in splices to actually build. Yipes. -}
mangleCode :: String -> String
mangleCode = fix_bad_escape . remove_package_version
  where
	{- GHC may incorrectly escape "}" within a multi-line string. -}
	fix_bad_escape = replace " \\}" " }"

	{- GHC may add full package and version qualifications for
	 - symbols from unimported modules. We don't want these.
	 -
	 - Examples:
	 -   "blaze-html-0.4.3.1:Text.Blaze.Internal.preEscapedText" 
	 -   "ghc-prim:GHC.Types.:"
	 -}
	remove_package_version s = case parse findQualifiedSymbols "" s of
		Left e -> s
		Right symbols -> concat $ 
			map (either (\c -> [c]) mangleSymbol) symbols

	findQualifiedSymbols :: Parser [Either Char String]
	findQualifiedSymbols = many $
		try (Right <$> qualifiedSymbol) <|> (Left <$> anyChar)

	qualifiedSymbol :: Parser String
	qualifiedSymbol = do
		token
		char ':'
		token

	token :: Parser String
	token = many1 $ satisfy isAlphaNum <|> oneOf "-.'"

	mangleSymbol "GHC.Types." = ""
	mangleSymbol s = s

main = do
	r <- parseFromFile splicesExtractor "log"
	case r of
		Left e -> error $ show e
		Right splices -> do
			let groups = groupBy (\a b -> splicedFile a == splicedFile b) splices
			imports <- catchMaybeIO $ readFile "imports"
			mapM_ (applySplices imports) groups