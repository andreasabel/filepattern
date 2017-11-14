{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE ViewPatterns #-}

module FilePattern.Internal(
    -- * Primitive API, as exposed
    FilePattern, matchWith,
    -- * General API, used by other people.
    filePatternWith,
    -- * Optimisation opportunities
    simpleWith,
    -- * Multipattern file rules
    compatibleWith, extractWith, substituteWith,
    -- * Accelerated searching
    Walk(..), walkWith,
    -- * Testing only
    isRelativePath, isRelativePattern,
    -- * Internal use only
    Lexeme(..), Pat(..), parseWith
    ) where

import Control.Applicative
import Control.Monad
import Data.Char
import Data.List.Extra
import Data.Maybe
import Data.Tuple.Extra
import Prelude
import System.FilePath (isPathSeparator)
import System.Info.Extra


-- | A type synonym for file patterns, containing @\/\/@ and @*@. For the syntax
--   and semantics of 'FilePattern' see '?=='.
--
--   Most 'normaliseEx'd 'FilePath' values are suitable as 'FilePattern' values which match
--   only that specific file. On Windows @\\@ is treated as equivalent to @\/@.
--
--   You can write 'FilePattern' values as a literal string, or build them
--   up using the operators 'Development.Shake.FilePath.<.>', 'Development.Shake.FilePath.</>'
--   and 'Development.Shake.<//>'. However, beware that:
--
-- * On Windows, use 'Development.Shake.FilePath.<.>' from "Development.Shake.FilePath" instead of from
--   "System.FilePath" - otherwise @\"\/\/*\" \<.\> exe@ results in @\"\/\/*\\\\.exe\"@.
--
-- * If the second argument of 'Development.Shake.FilePath.</>' has a leading path separator (namely @\/@)
--   then the second argument will be returned.
type FilePattern = String


---------------------------------------------------------------------
-- PATTERNS

data Pat = Lit String -- ^ foo
         | Star   -- ^ /*/
         | Skip -- ^ //
         | Skip1 -- ^ //, but must be at least 1 element
         | Stars String [String] String -- ^ *foo*, prefix (fixed), infix floaters, suffix
                                        -- e.g. *foo*bar = Stars "" ["foo"] "bar"
            deriving (Show,Eq,Ord)

isLit Lit{} = True; isLit _ = False
fromLit (Lit x) = x


data Lexeme = Str String | Slash | SlashSlash


-- | Parse a FilePattern with a given lexer. All optimisations I can think of are invalid because they change the extracted expressions.
parseWith :: (FilePattern -> [Lexeme]) -> FilePattern -> [Pat]
parseWith lex = f False True . lex
    where
        -- str = I have ever seen a Str go past (equivalent to "can I be satisfied by no paths")
        -- slash = I am either at the start, or my previous character was Slash
        f str slash [] = [Lit "" | slash]
        f str slash (Str "**":xs) = Skip : f True False xs
        f str slash (Str x:xs) = parseLit x : f True False xs
        f str slash (SlashSlash:Slash:xs) | not str = Skip1 : f str True xs
        f str slash (SlashSlash:xs) = Skip : f str False xs
        f str slash (Slash:xs) = [Lit "" | not str] ++ f str True xs


parseLit :: String -> Pat
parseLit "*" = Star
parseLit x = case split (== '*') x of
    [x] -> Lit x
    pre:xs | Just (mid,post) <- unsnoc xs -> Stars pre mid post


-- | Optimisations that may change the matched expressions
optimise :: [Pat] -> [Pat]
optimise (Skip:Skip:xs) = optimise $ Skip:xs
optimise (Skip:Star:xs) = optimise $ Skip1:xs
optimise (Star:Skip:xs) = optimise $ Skip1:xs
optimise (x:xs) = x : optimise xs
optimise [] =[]


-- | A 'FilePattern' that will only match 'isRelativePath' values.
isRelativePattern :: FilePattern -> Bool
isRelativePattern ('*':'*':xs)
    | [] <- xs = True
    | x:xs <- xs, isPathSeparator x = True
isRelativePattern _ = False

-- | A non-absolute 'FilePath'.
isRelativePath :: FilePath -> Bool
isRelativePath (x:_) | isPathSeparator x = False
isRelativePath (x:':':_) | isWindows, isAlpha x = False
isRelativePath _ = True


-- | Given a pattern, and a list of path components, return a list of all matches
--   (for each wildcard in order, what the wildcard matched).
match :: [Pat] -> [String] -> [[String]]
match (Skip:xs) (y:ys) = map ("":) (match xs (y:ys)) ++ match (Skip1:xs) (y:ys)
match (Skip1:xs) (y:ys) = [(y++"/"++r):rs | r:rs <- match (Skip:xs) ys]
match (Skip:xs) [] = map ("":) $ match xs []
match (Star:xs) (y:ys) = map (y:) $ match xs ys
match (Lit x:xs) (y:ys) = concat $ [match xs ys | x == y] ++ [match xs (y:ys) | x == "."]
match (x@Stars{}:xs) (y:ys) | Just rs <- matchStars x y = map (rs ++) $ match xs ys
match [] [] = [[]]
match _ _ = []


matchOne :: Pat -> String -> Bool
matchOne (Lit x) y = x == y
matchOne x@Stars{} y = isJust $ matchStars x y
matchOne Star _ = True


-- Only return the first (all patterns left-most) valid star matching
matchStars :: Pat -> String -> Maybe [String]
matchStars (Stars pre mid post) x = do
    x <- stripPrefix pre x
    x <- if null post then Just x else stripSuffix post x
    stripInfixes mid x
    where
        stripInfixes [] x = Just [x]
        stripInfixes (m:ms) x = do
            (a,x) <- stripInfix m x
            (a:) <$> stripInfixes ms x

matchWith :: (FilePattern -> [Pat]) -> FilePattern -> FilePath -> Bool
matchWith parser p = case optimise $ parser p of
    [x] | x == Skip || x == Skip1 -> if rp then isRelativePath else const True
    p -> let f = not . null . match p . split isPathSeparator
         in if rp then (\x -> isRelativePath x && f x) else f
    where rp = isRelativePattern p


-- | Like '?==', but returns 'Nothing' on if there is no match, otherwise 'Just' with the list
--   of fragments matching each wildcard. For example:
--
-- @
-- 'filePattern' \"**\/*.c\" \"test.txt\" == Nothing
-- 'filePattern' \"**\/*.c\" \"foo.c\" == Just [\"",\"foo\"]
-- 'filePattern' \"**\/*.c\" \"bar\/baz\/foo.c\" == Just [\"bar\/baz/\",\"foo\"]
-- @
--
--   Note that the @**@ will often contain a trailing @\/@, and even on Windows any
--   @\\@ separators will be replaced by @\/@.
filePatternWith :: (FilePattern -> [Pat]) -> FilePattern -> FilePath -> Maybe [String]
filePatternWith parse p = \x -> if eq x then Just $ ex x else Nothing
    where eq = matchWith parse p
          ex = extractWith parse p

---------------------------------------------------------------------
-- MULTIPATTERN COMPATIBLE SUBSTITUTIONS

specialsWith :: (FilePattern -> [Pat]) -> FilePattern -> [Pat]
specialsWith parse = concatMap f . parse
    where
        f Lit{} = []
        f Star = [Star]
        f Skip = [Skip]
        f Skip1 = [Skip]
        f (Stars _ xs _) = replicate (length xs + 1) Star

-- | Is the pattern free from any * and //.
simpleWith :: (FilePattern -> [Pat]) -> FilePattern -> Bool
simpleWith parse = null . specialsWith parse

-- | Do they have the same * and // counts in the same order
compatibleWith :: (FilePattern -> [Pat]) -> [FilePattern] -> Bool
compatibleWith _ [] = True
compatibleWith parse (x:xs) = all ((==) (specialsWith parse x) . specialsWith parse) xs

-- | Extract the items that match the wildcards. The pair must match with '?=='.
extractWith :: (FilePattern -> [Pat]) -> FilePattern -> FilePath -> [String]
extractWith parse p = let pat = parse p in \x ->
    case match pat (split isPathSeparator x) of
        [] | matchWith parse p x -> error $ "extract with " ++ show p ++ " and " ++ show x
           | otherwise -> error $ "Pattern " ++ show p ++ " does not match " ++ x ++ ", when trying to extract the FilePattern matches"
        ms:_ -> ms


-- | Given the result of 'extract', substitute it back in to a 'compatible' pattern.
--
-- > p '?==' x ==> substitute (extract p x) p == x
substituteWith :: (FilePattern -> [Pat]) -> [String] -> FilePattern -> FilePath
substituteWith parse oms oxs = intercalate "/" $ concat $ snd $ mapAccumL f oms (parse oxs)
    where
        f ms (Lit x) = (ms, [x])
        f (m:ms) Star = (ms, [m])
        f (m:ms) Skip = (ms, split m)
        f (m:ms) Skip1 = (ms, split m)
        f ms (Stars pre mid post) = (ms2, [concat $ pre : zipWith (++) ms1 (mid++[post])])
            where (ms1,ms2) = splitAt (length mid + 1) ms
        f _ _ = error $ "Substitution failed into pattern " ++ show oxs ++ " with " ++ show (length oms) ++ " matches, namely " ++ show oms

        split = linesBy (== '/')


---------------------------------------------------------------------
-- EFFICIENT PATH WALKING

-- | Given a list of files, return a list of things I can match in this directory
--   plus a list of subdirectories and walks that apply to them.
--   Use WalkTo when the list can be predicted in advance
data Walk = Walk ([String] -> ([String],[(String,Walk)]))
          | WalkTo            ([String],[(String,Walk)])

walkWith :: (FilePattern -> [Pat]) -> [FilePattern] -> (Bool, Walk)
walkWith parse ps = (any (\p -> isEmpty p || not (null $ match p [""])) ps2, f ps2)
    where
        ps2 = map (filter (/= Lit ".") . optimise . parse) ps

        f (nubOrd -> ps)
            | all isLit fin, all (isLit . fst) nxt = WalkTo (map fromLit fin, map (fromLit *** f) nxt)
            | otherwise = Walk $ \xs ->
                (if finStar then xs else filter (\x -> any (`matchOne` x) fin) xs
                ,[(x, f ys) | x <- xs, let ys = concat [b | (a,b) <- nxt, matchOne a x], not $ null ys])
            where
                finStar = Star `elem` fin
                fin = nubOrd $ mapMaybe final ps
                nxt = groupSort $ concatMap next ps


next :: [Pat] -> [(Pat, [Pat])]
next (Skip1:xs) = [(Star,Skip:xs)]
next (Skip:xs) = (Star,Skip:xs) : next xs
next (x:xs) = [(x,xs) | not $ null xs]
next [] = []

final :: [Pat] -> Maybe Pat
final (Skip:xs) = if isEmpty xs then Just Star else final xs
final (Skip1:xs) = if isEmpty xs then Just Star else Nothing
final (x:xs) = if isEmpty xs then Just x else Nothing
final [] = Nothing

isEmpty = all (== Skip)
