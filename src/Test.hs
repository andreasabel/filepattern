{-# OPTIONS_GHC -fno-warn-deprecations #-} -- Because .Legacy is deprecated
{-# LANGUAGE RecordWildCards #-}

module Main(main) where

import Control.Exception.Extra
import Control.Monad
import Data.List.Extra
import Data.Maybe
import System.FilePattern.Type
import System.FilePattern(Walk(..))
import qualified System.FilePattern as New
import qualified System.FilePattern.Legacy as Old
import qualified System.FilePattern.Parser as Parser
import qualified Data.Set as Set
import System.FilePath(isPathSeparator, (</>))
import Data.IORef.Extra
import System.IO.Unsafe
import System.Info.Extra
import Test.QuickCheck
import Data.Functor
import Prelude


---------------------------------------------------------------------
-- TEST UTILITIES

assertBool :: Bool -> String -> [String] -> IO ()
assertBool b msg fields = unless b $ error $ unlines $
    ("ASSERTION FAILED: " ++ msg) : fields

assertException :: IO () -> [String] -> String -> [String] -> IO ()
assertException a parts msg fields = do
    res <- try_ a
    case res of
        Left e -> assertBool (all (`isInfixOf` show e) parts) msg $ ["Expected" #= parts, "Got" #= e] ++ fields
        Right _ -> assertBool False msg $ ["Expected" #= parts, "Got" #= "<No exception>"] ++ fields

(#=) :: Show a => String -> a -> String
(#=) a b = a ++ ": " ++ show b


newtype Pattern = Pattern FilePattern deriving (Show,Eq)
newtype Path    = Path    FilePath    deriving (Show,Eq)

-- Since / and * are the only "interesting" elements, just add ab to round out the set

instance Arbitrary Pattern where
    arbitrary = fmap Pattern $ listOf $ elements "\\/*ab."
    shrink (Pattern x) = map Pattern $ shrinkList (\x -> ['/' | x == '\\']) x

instance Arbitrary Path where
    arbitrary = fmap Path $ listOf $ elements "\\/ab."
    shrink (Path x) = map Path $ shrinkList (\x -> ['/' | x == '\\']) x


---------------------------------------------------------------------
-- SWITCHING

data Switch = Switch
    {name :: String
    ,legacy :: Bool
    ,parse :: FilePattern -> Pats
    ,matchBool :: FilePattern -> FilePath -> Bool
    ,match :: FilePattern -> FilePath -> Maybe [String]
    ,simple :: FilePattern -> Bool
    ,compatible :: [FilePattern] -> Bool
    ,substitute :: [String] -> FilePattern -> FilePath
    ,walk :: [FilePattern] -> (Bool, Walk)
    }

switches :: [Switch]
switches =
    [Switch "System.FilePattern"        False Parser.parse       (New.?==) New.match New.simple New.compatible New.substitute New.walk
    ,Switch "System.FilePattern.Legacy" True  Parser.parseLegacy (Old.?==) Old.match Old.simple Old.compatible Old.substitute Old.walk
    ]

-- Unsafe because it traces all arguments going through.
-- Useful to see the property phase with all things that have gone before.
-- Not a problem because it's in the test suite.
unsafeSwitchTrace :: Switch -> IO (IO [String], Switch)
unsafeSwitchTrace Switch{..} = do
    seen <- newIORef Set.empty
    let adds f xs = unsafePerformIO $ do
            modifyIORef' seen $ \mp -> foldl' (flip Set.insert) mp xs
            return $ f xs
    let add f x = adds (f . head) [x]
    let get = Set.toList <$> readIORef seen
    return $ (,) get $ Switch name legacy
        (add parse)
        (add . add matchBool)
        (add . add match)
        (add simple)
        (adds compatible)
        (add . adds substitute)
        (adds walk)


-- | Write 'matchBool' in terms of 'walker'.
walkerMatch :: Switch -> FilePattern -> FilePath -> Bool
walkerMatch Switch{..} a b = if null b2 then empty else f b2 w
    where
        b2 = filter (/= ".") $ split isPathSeparator b
        (empty, w) = walk [a]

        f (x:xs) (Walk op) = f (x:xs) $ WalkTo $ op [x]
        f [x]    (WalkTo (file, dir)) = x `elem` file
        f (x:xs) (WalkTo (file, dir)) | Just w <- lookup x dir = f xs w
        f _ _ = False

showWalk :: Walk -> String
showWalk (Walk _) = "Walk _"
showWalk (WalkTo (p,xs)) = "WalkTo " ++ pair (show p) (list [pair (show a) (showWalk b) | (a,b) <- xs])
    where
        pair a b = "(" ++ a ++ "," ++ b ++ ")"
        list xs = "[" ++ intercalate "," xs ++ "]"


---------------------------------------------------------------------
-- DRIVER

main :: IO ()
main = do
    let dot x = putStr "." >> x
    forM_ switches $ \switch@Switch{..} -> do
        putStr $ "Testing " ++ name ++ " "
        dot $ when legacy testLegacyWarning
        (get, s) <- unsafeSwitchTrace switch
        dot $ testParser s
        dot $ testSimple s
        dot $ testCompatible s
        dot $ testSubstitute s
        dot $ testMatch s
        dot $ testWalk s
        putStr " "
        testProperties switch =<< get


-- Check that 'addUnsafeLegacyWarning' works and fires at the right times
testLegacyWarning :: IO ()
testLegacyWarning = do
    ref <- newIORef Nothing
    Old.addUnsafeLegacyWarning $ \x -> modifyIORef ref $ fmap (++ [x])

    let x # b = do
            writeIORef ref $ Just []
            evaluate $ Old.compatible [x,x]
            got <- readIORef ref
            writeIORef ref Nothing -- to avoid a memory leak
            let expected = Just $ if b then [x,x] else []
            assertBool (expected == got) "legacyWarning" ["Input" #= x, "Expected" #= expected, "Got" #= got]

    "foo/**/x" # False
    "foo/x//y" # True
    "foo//x//y" # True
    "foo/**/x/*.foo" # False


testParser :: Switch -> IO ()
testParser Switch{..} = do
    let x # y = assertBool (res == y) "testParser" ["Name" #= name, "Input" #= x, "Expected" #= y, "Got" #= res]
            where Pats res = parse x
    "" # [lit ""]
    "x" # [lit "x"]
    "/" # [lit "",lit ""]
    "x/" # [lit "x",lit ""]
    "/x" # [lit "",lit "x"]
    "x/y" # [lit "x",lit "y"]
    "//" # if legacy then [Skip] else [lit "", lit ""]
    "**" # [Skip]
    "//x" # if legacy then [Skip, lit "x"] else [lit "", lit "x"]
    "**/x" # [Skip, lit "x"]
    "x//" # if legacy then [lit "x", Skip] else [lit "x", lit ""]
    "x/**" # [lit "x", Skip]
    "x//y" # if legacy then [lit "x",Skip, lit "y"] else [lit "x", lit "y"]
    "///" # if legacy then [star, Skip, lit ""] else [lit "", lit ""]
    "**/**" # [Skip,Skip]
    "**/**/" # [Skip, Skip, lit ""]
    "///x" # if legacy then [star, Skip, lit "x"] else [lit "", lit "x"]
    "**/x" # [Skip, lit "x"]
    "x///" # if legacy then [lit "x", Skip, lit ""] else [lit "x", lit ""]
    "x/**/" # [lit "x", Skip, lit ""]
    "x///y" # if legacy then [lit "x",Skip, lit "y"] else [lit "x", lit "y"]
    "x/**/y" # [lit "x",Skip, lit "y"]
    "////" # if legacy then [Skip, Skip] else [lit "", lit ""]
    "**/**/**" # [Skip, Skip, Skip]
    "////x" # if legacy then [Skip, Skip, lit "x"] else [lit "", lit "x"]
    "x////" # if legacy then [lit "x", Skip, Skip] else [lit "x", lit ""]
    "x////y" # if legacy then [lit "x",Skip, Skip, lit "y"] else [lit "x", lit "y"]
    "**//x" # if legacy then [Skip, Skip, lit "x"] else [Skip, lit "x"]


testSimple :: Switch -> IO ()
testSimple Switch{..} = do
    let x # y = assertBool (res == y) "simple" ["Name" #= name, "Input" #= x, "Expected" #= y, "Got" #= res]
            where res = simple x
    "a*b" # False
    "a//b" # not legacy
    "a/**/b" # False
    "/a/b/cccc_" # True
    "a///b" # not legacy
    "a/**/b" # False


testCompatible :: Switch -> IO ()
testCompatible Switch{..} = do
    let x # y = assertBool (res == y) "compatible" ["Name" #= name, "Input" #= x, "Expected" #= y, "Got" #= res]
            where res = compatible x
    [] # True
    ["foo/**/*"] # True
    ["//*a.txt","foo//a*.txt"] # True
    ["**/*a.txt","foo/**/a*.txt"] # True
    ["//*a.txt","foo/**/a*.txt"] # legacy
    ["//*a.txt","foo//a*.*txt"] # False
    ["**/*a.txt","foo/**/a*.*txt"] # False


testSubstitute :: Switch -> IO ()
testSubstitute Switch{..} = do
    let f a b c = assertBool (res == c) "substitute" ["Name" #= name, "Parts" #= a, "Pattern" #= b, "Expected" #= c, "Got" #= res]
            where res = substitute a b
    when legacy $ f ["","test","da"] "//*a*.txt" "testada.txt"
    f ["","test","da"] "**/*a*.txt" "testada.txt"
    when legacy $ f ["foo/bar/","test"] "//*a.txt" "foo/bar/testa.txt"
    f ["foo/bar/","test"] "**/*a.txt" "foo/bar/testa.txt"
    let deep = void . evaluate . length . show
    -- error if the number of replacements is wrong
    assertException (deep $ substitute ["test"] "nothing") ["substitute","wanted 0","got 1","test","nothing"] "substitute" []
    assertException (deep $ substitute ["test"] "*/*") ["substitute","wanted 2","got 1","test","*/*"] "substitute" []


testMatch :: Switch -> IO ()
testMatch Switch{..} = do
    let f a b c = assertBool (res == c) "match" ["Name" #= name, "Pattern" #= a, "File" #= b, "Expected" #= c, "Got" #= res]
            where res = match a b
    let yes a b c = f a b $ Just c
    let no a b = f a b Nothing
    let old a b c = f a b $ if legacy then Just c else Nothing -- works only with the old one
    let diff a b c d = yes a b $ if legacy then c else d -- works differently with old and new

    old "//*.c" "foo/bar/baz.c" ["foo/bar/","baz"]
    diff "//*.c" "/baz.c" ["/","baz"] ["baz"]
    yes "**/*.c" "foo/bar/baz.c" ["foo/bar/","baz"]
    yes ("**" </> "*.c") ("foo/bar" </> "baz.c") ["foo/bar/","baz"]
    yes "*.c" "baz.c" ["baz"]
    old "//*.c" "baz.c" ["","baz"]
    yes "**/*.c" "baz.c" ["","baz"]
    yes "**/*a.txt" "foo/bar/testa.txt" ["foo/bar/","test"]
    no "**/*.c" "baz.txt"
    yes "**/*a.txt" "testa.txt" ["","test"]
    yes "**/a.txt" "a.txt" [""]
    yes "a/**/b" "a/b" [""]
    yes "a/**/b" "a/x/b" ["x/"]
    yes "a/**/b" "a/x/y/b" ["x/y/"]
    yes "a/**/**/b" "a/x/y/b" ["","x/y/"]
    yes "**/*a*.txt" "testada.txt" ["","test","da"]
    yes "test.c" "test.c" []
    no "*.c" "foor/bar.c"
    no "*/*.c" "foo/bar/baz.c"
    no "foo//bar" "foobar"
    no "foo/**/bar" "foobar"
    no "foo//bar" "foobar/bar"
    no "foo/**/bar" "foobar/bar"
    no "foo//bar" "foo/foobar"
    no "foo/**/bar" "foo/foobar"
    diff "foo//bar" "foo/bar" [""] []
    yes "foo/**/bar" "foo/bar" [""]
    yes "foo/bar" ("foo" </> "bar") []
    yes ("foo" </> "bar") "foo/bar" []
    yes ("foo" </> "bar") ("foo" </> "bar") []
    yes "**/*.c" ("bar" </> "baz" </> "foo.c") ["bar/baz/","foo"]
    diff "//*" "/bar" ["/","bar"] ["bar"]
    yes "**/*" "/bar" ["/","bar"]
    old "/bob//foo" "/bob/this/test/foo" ["this/test/"]
    diff "/bob//foo" "/bob/foo" [""] []
    yes "/bob/**/foo" "/bob/this/test/foo" ["this/test/"]
    no "/bob//foo" "bob/this/test/foo"
    no "/bob/**/foo" "bob/this/test/foo"
    old "bob//foo/" "bob/this/test/foo/" ["this/test/"]
    diff "bob//foo/" "bob/foo/" [""] []
    yes "bob/**/foo/" "bob/this/test/foo/" ["this/test/"]
    no "bob//foo/" "bob/this/test/foo"
    no "bob/**/foo/" "bob/this/test/foo"
    yes ("**" </> "*a*.txt") "testada.txt" ["","test","da"]
    old "a//" "a" [""]
    yes "a/**" "a" [""]
    diff "a//" "a/" ["/"] []
    old "/a//" "/a" [""]
    yes "a/**" "a" [""]
    diff "/a//" "/a/" ["/"] []
    yes "/a/**" "/a" [""]
    old "///a//" "/a" ["","",""]
    diff "///a//" "/a/" ["","","/"] []
    yes "**/a/**" "/a" ["/",""]
    no "///" ""
    diff "///" "/" ["",""] []
    yes "/**" "/" ["/"]
    yes "**/" "a/" ["a/"]
    diff "////" "/" ["","//"] []
    yes "**/**" "" ["","/"]
    diff "x///y" "x/y" [""] []
    yes "x/**/y" "x/y" [""]
    diff "x///" "x/" [""] []
    yes "x/**/" "x/" [""]
    yes "x/**/" "x/foo/" ["foo/"]
    no "x///" "x"
    no "x/**/" "x"
    yes "x/**/" "x/foo/bar/" ["foo/bar/"]
    no "x///" "x/foo/bar"
    no "x/**/" "x/foo/bar"
    diff "x///y" "x/y" [""] []
    yes "x/**/*/y" "x/z/y" ["","z"]
    yes "" "" []
    no "" "y"
    no "" "/"

    yes "*/*" "x/y" ["x","y"]
    no "*/*" "x"
    diff "//*" "/x" ["/","x"] ["x"]
    yes "**/*" "x" ["","x"]
    diff "//*" "/" ["/",""] [""]
    yes "**/*" "" ["",""]
    diff "*//" "x/" ["x","/"] ["x"]
    yes "*/**" "x" ["x",""]
    diff "*//" "/" ["","/"] [""]
    diff "*//*" "x/y" ["x","","y"] ["x","y"]
    yes "*/**/*" "x/y" ["x","","y"]
    no "*//*" ""
    no "*/**/*" ""
    no "*//*" "x"
    no "*/**/*" "x"
    no "*//*//*" "x/y"
    no "*/**/*/**/*" "x/y"
    diff "//*/" "//" ["/",""] [""]
    yes "**/*/" "/" ["",""]
    diff "*/////" "/" ["","",""] [""]
    yes "*/**/**/" "/" ["","",""]
    no "b*b*b*//" "bb"
    no "b*b*b*/**" "bb"

    yes "**" "/" ["//"]
    yes "**/x" "/x" ["/"]
    yes "**" "x/" ["x//"]
    let s = if isWindows then '/' else '\\'
    yes "**" "\\\\drive" [s:s:"drive/"]
    yes "**" "C:\\drive" ["C:"++s:"drive/"]
    yes "**" "C:drive" ["C:drive/"]

    -- We support ignoring '.' values in FilePath as they are inserted by @filepath@ a lot
    yes "./file" "file" []
    no "/file" "file"
    yes "foo/./bar" "foo/bar" []
    yes "foo/./bar" "foo/./bar" []
    yes "foo/./bar" "foo/bar" []


testWalk :: Switch -> IO ()
testWalk Switch{..} = do
    let shw (a, b) = "(" ++ show a ++ "," ++ showWalk b ++ ")"
    let both p w = assertBool (shw res == shw w) "walk" ["Name" #= name, "Pattern" #= p, "Expected" #= shw w, "Got" #= shw res]
            where res = walk p
    let diff p w1 w2 = both p $ if legacy then w1 else w2
    let walk_ = Walk undefined

    both ["*.xml"] (False, walk_)
    diff ["//*.xml"] (False, walk_) (False, WalkTo ([], [("",walk_)]))
    both ["**/*.xml"] (False, walk_)
    both ["foo//*.xml"] (False, WalkTo ([], [("foo",walk_)]))
    both ["foo/**/*.xml"] (False, WalkTo ([], [("foo",walk_)]))
    both ["foo/bar/*.xml"] (False, WalkTo ([], [("foo",WalkTo ([],[("bar",walk_)]))]))
    both ["a","b/c"] (False, WalkTo (["a"],[("b",WalkTo (["c"],[]))]))
    let (False, Walk f) = walk ["*/bar/*.xml"]
        shw2 = showWalk . WalkTo
    assertBool (shw2 (f ["foo"]) == shw2 ([], [("foo",WalkTo ([],[("bar",walk_)]))])) "walk inner" []
    both ["bar/*.xml","baz//*.c"] (False, WalkTo ([],[("bar",walk_),("baz",walk_)]))
    both ["bar/*.xml","baz/**/*.c"] (False, WalkTo ([],[("bar",walk_),("baz",walk_)]))
    both [] (False, WalkTo ([], []))
    both [""] (True, WalkTo ([""], []))
    diff ["//"] (True, walk_) (False, WalkTo ([], [("",WalkTo ([""],[]))]))
    both ["**"] (True, walk_)


testProperties :: Switch -> [String] -> IO ()
testProperties switch@Switch{..} xs = do
    forM_ xs $ \x -> forM_ xs $ \y -> prop x y
    Success{} <- quickCheckWithResult stdArgs{maxSuccess=10000} $ \(Pattern p) (Path x) ->
        (if matchBool p x then label "match" else property) $ unsafePerformIO $ prop p x >> return True
    return ()
    where
        prop :: FilePattern -> FilePath -> IO ()
        prop pat file = do
            let b = matchBool pat file
            let fields = ["Name" #= name, "Pattern" #= pat, "File" #= file, "?==" #= b]
            let res = match pat file in assertBool (b == isJust (match pat file)) "match" $ fields ++ ["match" #= res]
            let res = walkerMatch switch pat file in assertBool (b == res) "walker" $ fields ++ ["walker" #= res]
            let res = compatible [pat,pat] in assertBool res "compatible" fields
            let norm = (\x -> if null x then [""] else x) . filter (/= ".") . split isPathSeparator
            when b $ let res = substitute (fromJust $ match pat file) pat in
                assertBool (norm res == norm file) "substitute" $ fields ++ ["Match" #= match pat file, "Got" #= res, "Input (norm)" #= norm file, "Got (norm)" #= norm res]
