{-# LANGUAGE OverloadedStrings, PackageImports, LambdaCase #-}
{-# LANGUAGE FlexibleContexts #-}
module Main where

import Data.List
import Control.Applicative
import Control.Arrow
import Control.Concurrent
import Control.Concurrent.Async
import Control.Monad
import Control.Monad.Reader

import System.Environment
import System.Exit
import System.Directory
import System.FilePath
import System.IO
import Control.Exception hiding (catch)
import Control.Monad.Trans.Control
import Control.Monad.Catch
import Control.DeepSeq
import qualified Data.Set as Set

import Pretty hiding ((</>))
import CGExp
import Driver
import CoreToIR
import IR (Backend(..))
import Text.Parsec.Pos

instance NFData SourcePos where
    rnf _ = ()

acceptPath = "./tests/accept"
rejectPath = "./tests/reject"
timeout = 15 {- in seconds -}

data Res = Accepted | New | Rejected | Failed | ErrorCatched
    deriving (Eq, Ord, Show)

erroneous = (>= Rejected)

instance NFData Res where
    rnf a = a `seq` ()

optionArgs = ["-v", "-r"]

main :: IO ()
main = do
  hSetBuffering stdout NoBuffering
  hSetBuffering stdin NoBuffering
  args <- getArgs

  let samplesToAccept = filter (not . flip elem optionArgs) args
      verbose = elem "-v" args
      reject  = elem "-r" args
  (testToAccept,testToReject) <- case samplesToAccept of
    [] -> do
      toAccept <- map dropExtension . filter (\n -> ".lc" == takeExtension n) <$> getDirectoryContents acceptPath
      toReject <- map dropExtension . filter (\n -> ".lc" == takeExtension n) <$> getDirectoryContents rejectPath
      return (toAccept, toReject)
    _ -> do
      let intersect = Set.toList . Set.intersection (Set.fromList samplesToAccept) . Set.fromList
      toAccept <- intersect . map dropExtension . filter (\n -> ".lc" == takeExtension n) <$> getDirectoryContents acceptPath
      toReject <- intersect . map dropExtension . filter (\n -> ".lc" == takeExtension n) <$> getDirectoryContents rejectPath
      return (toAccept, toReject)

  n <- runMM' $ do
      liftIO $ putStrLn $ "------------------------------------ Checking valid pipelines"
      n1 <- acceptTests reject testToAccept

      liftIO $ putStrLn $ "------------------------------------ Catching errors (must get an error)"
      n2 <- rejectTests reject testToReject

      return $ n1 ++ n2

  let sh b ty = [(if erroneous ty then "!" else "") ++ show (length ss) ++ " " ++ pad 10 (b ++ ": ") ++ intercalate ", " ss | not $ null ss]
          where
            ss = sort [s | (ty', s) <- n, ty' == ty]
  let results = [t | (t,_) <- n]

  putStrLn $ "------------------------------------ Summary\n" ++
    if null n 
        then "All OK"
        else unlines $
            sh "crashed test" ErrorCatched
         ++ sh "failed test" Failed
         ++ sh "rejected result" Rejected
         ++ sh "new result" New
         ++ sh "accepted result" Accepted
  when (any erroneous results) exitFailure

acceptTests reject = testFrame reject [acceptPath, rejectPath] $ \case
    Left e -> Left e
    Right (Left e) -> Right ("typechecked", show e)
    Right (Right e)
        | tyOf e == TCon0 "Output"
            -> Right ("compiled main", show . compilePipeline True OpenGL33 $ e)
        | tyOf e == TCon0 "Bool" -> case e of
            x@(A0 "True") -> Right ("main ~~> True", ppShow x)
            x -> Left $ "main should be True but it is \n" ++ ppShow x
        | otherwise -> Right ("reduced main " ++ ppShow (tyOf e), ppShow e)
--        | otherwise -> Right ("System-F main ", ppShow . toCore mempty $ e)

rejectTests reject = testFrame reject [rejectPath, acceptPath] $ \case
    Left e -> Right ("error message", e)
    Right (Left e) -> Left "failed to catch error"
    Right (Right e) -> Left "failed to catch error"

runMM' = fmap (either (error "impossible") id . fst) . runMM (ioFetch [])

testFrame reject dirs f tests
    = local (const $ ioFetch dirs') . testFrame_ compare (head dirs') (\n -> do
        result <- catchMM $ getDef (ExpN n) (ExpN "main") Nothing
        return $ f (((\(r, infos) -> infos `deepseq` r) <$>) <$> result)) $ tests
  where
    compare = if reject then alwaysReject else compareResult
    dirs_ = [takeDirectory f | f <- tests, takeFileName f /= f]
    dirs' = if null dirs_ then dirs else dirs_


timeOut :: Int -> a -> MM a -> MM a
timeOut n d m = MMT $
  control (\runInIO ->
    race' (runInIO (runMMT m))
          (threadDelay (n * 1000000) >> (runInIO $ return d)))
  where
    race' a b = either id id <$> race a b

testFrame_ compareResult path action tests = fmap concat $ forM (zip [1..] (tests :: [String])) $ \(i, n) -> do
    let er e = do
            liftIO $ putStrLn $ "\n!Crashed " ++ n ++ "\n" ++ tab e
            return [(ErrorCatched, n)]
    catchErr er $ do
        result <- timeOut timeout (Left "Timed Out") (action n)
        liftIO $ case result of
          Left e -> do
            putStrLn $ "\n!Failed " ++ n ++ "\n" ++ tab e
            return [(Failed, n)]
          Right (op, x) -> do
            length x `seq` compareResult n (pad 15 op) (path </> (n ++ ".out")) x
  where
    tab = unlines . map ("  " ++) . lines

-- Reject unrigestered or chaned results automatically
alwaysReject n msg ef e = doesFileExist ef >>= \b -> case b of
    False -> putStrLn ("Unregistered - " ++ msg) >> return [(Rejected, n)]
    True -> do
        e' <- readFile ef
        case map fst $ filter snd $ zip [0..] $ zipWith (/=) e e' of
          [] -> return []
          rs -> do
            putStrLn $ msg ++ " has changed."
            putStrLn "------------------------------------------- Old"
            putStrLn $ showRanges ef rs e'
            putStrLn "------------------------------------------- New"
            putStrLn $ showRanges ef rs e
            putStrLn "-------------------------------------------"
            return [(Rejected, n)]

compareResult n msg ef e = doesFileExist ef >>= \b -> case b of
    False -> writeFile ef e >> putStrLn ("OK - " ++ msg ++ " is written") >> return [(New, n)]
    True -> do
        e' <- readFile ef
        case map fst $ filter snd $ zip [0..] $ zipWith (/=) e e' ++ replicate (abs $  length e - length e') True of
          [] -> return []
          rs -> do
            putStrLn $ msg ++ " has changed."
            putStrLn "------------------------------------------- Old"
            putStrLn $ showRanges ef rs e'
            putStrLn "------------------------------------------- New"
            putStrLn $ showRanges ef rs e
            putStrLn "-------------------------------------------"
            putStr $ "Accept new " ++ msg ++ " (y/n)? "
            c <- length e' `seq` getChar
            if c `elem` ("yY\n" :: String)
                then writeFile ef e >> putStrLn " - accepted." >> return [(Accepted, n)]
                else putStrLn " - not Accepted." >> return [(Rejected, n)]

pad n s = s ++ replicate (n - length s) ' '

limit :: String -> Int -> String -> String
limit msg n s = take n s ++ if null (drop n s) then "" else msg

showRanges :: String -> [Int] -> String -> String
showRanges fname is e = (if head rs == 0 then "" else "...\n")
    ++ limit ("\n... (see " ++ fname ++ " for more differences)") 140000 (intercalate "\n...\n" $ f (zipWith (-) rs (0:rs)) e)
  where
    f :: [Int] -> String -> [String]
    f (i:is) e = g is $ drop i e
    f [] "" = []
    f [] _ = ["\n..."]
    g (i:is) e = take i e: f is (drop i e)
    rs = (head is - x) : concat [[a + x, b - x] | (a, b) <- zip is (tail is), a + y < b] ++ [last is + x]
    x = 100000
    y = 3*x

