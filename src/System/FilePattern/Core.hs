{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE ViewPatterns #-}

-- | This library supports patterns containing @*@ and @**@, but also
--   \"legacy\" patterns including @\/\/@ as well.
--   To support that, we have 'with' patterns that are customized by the lexer.
module System.FilePattern.Core(
    -- * Primitive API, as exposed
    FilePattern, matchBoolWith, matchWith,
    -- * Optimisation opportunities
    simpleWith,
    -- * Multipattern file rules
    compatibleWith, substituteWith,
    -- * Accelerated searching
    Walk(..), walkWith
    ) where

import Control.Applicative
import Data.List.Extra
import Data.Maybe
import Data.Tuple.Extra
import Prelude
import System.FilePattern.Type
import System.FilePath (isPathSeparator)


---------------------------------------------------------------------
-- PATTERNS

-- | Optimisations that may change the matched expressions
optimise :: [Pat] -> [Pat]
optimise (Skip1:xs) = optimise $ Star:Skip:xs
optimise (Skip:Skip:xs) = optimise $ Skip:xs
optimise (Star:Skip:xs) = optimise $ Skip:Star:xs
optimise (x:xs) = x : optimise xs
optimise [] = []


-- | Given a pattern, and a list of path components, return a list of all matches
--   (for each wildcard in order, what the wildcard matched).
match :: [Pat] -> [String] -> [[String]]
match (Skip:xs) (y:ys) = map ("":) (match xs (y:ys)) ++ match (Skip1:xs) (y:ys)
match (Skip1:xs) (y:ys) = [(y++"/"++r):rs | r:rs <- match (Skip:xs) ys]
match (Skip:xs) [] = map ("":) $ match xs []
match (Star:xs) (y:ys) = map (y:) $ match xs ys
match (Lit x:xs) (y:ys) = concat $ [match xs ys | x == y] ++ [match xs (y:ys) | x == "."]
match (Stars x:xs) (y:ys) | Just rs <- wildcard x y = map (rs ++) $ match xs ys
match [] [] = [[]]
match _ _ = []


matchOne :: Pat -> String -> Bool
matchOne (Lit x) y = x == y
matchOne (Stars x) y = isJust $ wildcard x y
matchOne Star _ = True
matchOne Skip _ = False
matchOne Skip1 _ = False


-- Only return the first (all patterns left-most) valid star matching
wildcard :: Eq a => Wildcard [a] -> [a] -> Maybe [[a]]
wildcard (Wildcard pre mid post) x = do
    y <- stripPrefix pre x
    z <- if null post then Just y else stripSuffix post y
    stripInfixes mid z
    where
        stripInfixes [] y = Just [y]
        stripInfixes (m:ms) y = do
            (a,z) <- stripInfix m y
            (a:) <$> stripInfixes ms z


matchBoolWith :: Pats -> FilePath -> Bool
matchBoolWith (Pats pat) = case optimise pat of
    [x] | x == Skip || x == Skip1 -> const True
        -- Skip1 is safe because split NEVER returns null
    p -> not . null . match p . split isPathSeparator


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
matchWith :: Pats -> FilePath -> Maybe [String]
matchWith (Pats ps) = listToMaybe . match ps . split isPathSeparator


---------------------------------------------------------------------
-- MULTIPATTERN COMPATIBLE SUBSTITUTIONS

specialsWith :: Pats -> [Pat]
specialsWith = concatMap f . fromPats
    where
        f Lit{} = []
        f Star = [Star]
        f Skip = [Skip]
        f Skip1 = [Skip]
        f (Stars (Wildcard _ xs _)) = replicate (length xs + 1) Star

-- | Is the pattern free from any * and //.
simpleWith :: Pats -> Bool
simpleWith = null . specialsWith

-- | Do they have the same * and // counts in the same order
compatibleWith :: [Pats] -> Bool
compatibleWith [] = True
compatibleWith (x:xs) = all ((==) (specialsWith x) . specialsWith) xs

-- | Given a successful 'match', substitute it back in to a 'compatible' pattern.
--
-- > p '?==' x ==> substitute (extract p x) p == x
substituteWith :: [String] -> Pats -> FilePath
substituteWith oms (Pats oxs) = intercalate "/" $ concat $ snd $ mapAccumL f oms oxs
    where
        f ms (Lit x) = (ms, [x])
        f (m:ms) Star = (ms, [m])
        f (m:ms) Skip = (ms, splitSep m)
        f (m:ms) Skip1 = (ms, splitSep m)
        f ms (Stars (Wildcard pre mid post)) = (ms2, [concat $ pre : zipWith (++) ms1 (mid++[post])])
            where (ms1,ms2) = splitAt (length mid + 1) ms
        f _ _ = error $ "Substitution failed into pattern " ++ show oxs ++ " with " ++ show (length oms) ++ " matches, namely " ++ show oms

        splitSep = linesBy (== '/')


---------------------------------------------------------------------
-- EFFICIENT PATH WALKING

-- | Given a list of files, return a list of things I can match in this directory
--   plus a list of subdirectories and walks that apply to them.
--   Use WalkTo when the list can be predicted in advance
data Walk = Walk ([String] -> ([String],[(String,Walk)]))
          | WalkTo            ([String],[(String,Walk)])

walkWith :: [Pats] -> (Bool, Walk)
walkWith patterns = (any (\p -> isEmpty p || not (null $ match p [""])) ps2, f ps2)
    where
        ps2 = map (filter (/= Lit ".") . optimise . fromPats) patterns

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

isEmpty :: [Pat] -> Bool
isEmpty = all (== Skip)