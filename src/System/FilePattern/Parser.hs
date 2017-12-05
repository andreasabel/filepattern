{-# LANGUAGE PatternGuards #-}

-- | Parsers for the flavours of 'FilePattern'.
module System.FilePattern.Parser(
    parse,
    parseLegacy,
    addUnsafeLegacyWarning
    ) where

import Control.Monad
import Data.List.Extra
import Data.Maybe
import Data.IORef
import System.IO.Unsafe
import Prelude
import System.FilePattern.Type
import System.FilePath (isPathSeparator)


---------------------------------------------------------------------
-- LEGACY WARNING

{-# NOINLINE legacyWarning #-}
legacyWarning :: IORef (FilePattern -> IO ())
legacyWarning = unsafePerformIO $ newIORef $ const $ return ()

-- | Add a callback that is run on every legacy pattern containing @\/\/@.
--   Note that the callback will be run via 'unsafePerformIO'.
addUnsafeLegacyWarning :: (FilePattern -> IO ()) -> IO ()
addUnsafeLegacyWarning act = atomicModifyIORef legacyWarning $ \old -> (old >> act, ())

{-# NOINLINE traceLegacyWarning #-}
traceLegacyWarning :: FilePattern -> a -> a
traceLegacyWarning pat x = unsafePerformIO $ do
    warn <- readIORef legacyWarning
    warn pat
    return x


---------------------------------------------------------------------
-- PATTERNS

data Lexeme = Str String | Slash | SlashSlash


-- | Parse a FilePattern with a given lexer. All optimisations I can think of are invalid because they change the extracted expressions.
parseLexeme :: [Lexeme] -> [Pat]
parseLexeme = f False True
    where
        -- str = I have ever seen a Str go past (equivalent to "can I be satisfied by no paths")
        -- slash = I am either at the start, or my previous character was Slash
        f _ slash [] = [Lit "" | slash]
        f _ _ (Str "**":xs) = Skip : f True False xs
        f _ _ (Str x:xs) = parseLit x : f True False xs
        f str _ (SlashSlash:Slash:xs) | not str = Skip1 : f str True xs
        f str _ (SlashSlash:xs) = Skip : f str False xs
        f str _ (Slash:xs) = [Lit "" | not str] ++ f str True xs


parseLit :: String -> Pat
parseLit "*" = Star
parseLit x = case split (== '*') x of
    [] -> error "parseLit: given empty string"
    [y] -> Lit y
    pre:xs -> case unsnoc xs of
        Nothing -> error "parseLit: Stars check failed"
        Just (mid,post) -> Stars $ Wildcard pre mid post


parseLegacy :: FilePattern -> Pats
parseLegacy x = Pats $ parseLexeme $ f x x
    where
        -- first argument is the original full pattern, or "" if we've already warned
        f o "" = []
        f o (x1:x2:xs) | isPathSeparator x1, isPathSeparator x2 =
            (if o == "" then id else traceLegacyWarning o) $ SlashSlash : f "" xs
        f o (x1:xs) | isPathSeparator x1 = Slash : f o xs
        f o xs = Str a : f o b
            where (a,b) = break isPathSeparator xs


parse :: FilePattern -> Pats
parse = Pats . parseLexeme . f
    where
        f "" = []
        f (x1:x2:xs) | isPathSeparator x1, isPathSeparator x2 = f (x2:xs)
        f (x1:xs) | isPathSeparator x1 = Slash : f xs
        f xs = Str a : f b
            where (a,b) = break isPathSeparator xs
