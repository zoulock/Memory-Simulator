module Algorithm where

import           Prelude
import           Process
import           Data.List
import qualified Data.SortedList               as S
import           Data.Maybe
import           Control.Monad.Writer
import           Debug.Trace

totalMemory :: Int
totalMemory = 2000

data Action = ProcessAddedToQueue Process
            | ProcessInserted ProcessInMemory
            | ProcessRemoved ProcessInMemory
            | CompactedMemory (S.SortedList ProcessInMemory) (S.SortedList Process.ProcessInMemory)
  deriving (Show)

gaps :: S.SortedList ProcessInMemory -> [(MemoryAddress, Int)]
gaps gs =
  catMaybes
    $   (\(a, b) ->
          if b - m a == 0 then Nothing else Just (MemoryAddress (m a), b - m a)
        )
    <$> zip (MemoryAddress 0 : (end <$> S.fromSortedList gs))
            (((m . address) <$> S.fromSortedList gs) ++ [totalMemory])

type Fit = S.SortedList ProcessInMemory -> Process -> Maybe MemoryAddress

freeSpace :: S.SortedList ProcessInMemory -> Int
freeSpace ps = sum $ snd <$> gaps ps

compact :: S.SortedList ProcessInMemory -> S.SortedList ProcessInMemory
compact ls = S.toSortedList $ scanl'
  (\a b@(ProcessInMemory _ t x) ->
    ProcessInMemory (MemoryAddress $ m (end a) + size b) t x
  )
  (ProcessInMemory (MemoryAddress 0) t0 px)
  ps
  where (ProcessInMemory _ t0 px : ps) = S.fromSortedList ls

shouldCompact :: S.SortedList ProcessInMemory -> Process -> Bool
shouldCompact ps p =
  freeSpace ps
    >= requiredMemory p
    && snd (head $ sortOn (\x -> (-1) * snd x) $ gaps ps)
    <  requiredMemory p

insertProcess
  :: S.SortedList ProcessInMemory
  -> MemoryAddress
  -> Int
  -> Process
  -> Writer [Action] (S.SortedList ProcessInMemory)
insertProcess ps a t p = do
  tell [ProcessInserted (ProcessInMemory a t p)]
  return (S.insert (ProcessInMemory a t p) ps)


type Log = (Int, Action)

step :: Fit -> (Fit -> SimState ->  Writer [Action] SimState) -> SimState -> Writer [Log] SimState
step f x s@(t, _, _) = mapWriter (\(n,w) -> (n, zip [t..t] w)) $
  do
    a <- issue s
    b <- removeFinishedProcesses a
    c <- insertFromQueue f x b
    return (incrementTime 1 c)

incrementTime :: Int -> SimState -> SimState
incrementTime d (t, a, b) = (t + d, a, b)

-- reads processes to be issued and adds them to the queue
issue :: SimState -> Writer [Action] SimState
issue (t, s, ps) = do
  tell (ProcessAddedToQueue <$> S.fromSortedList a)
  return (t, ProcessorState (processes s) (S.union (queue s) a), b)
  where (a, b) = S.span ((t ==) . arrivalTime) ps

insertFromQueue :: Fit -> (Fit -> SimState -> Writer [Action] SimState) -> SimState -> Writer [Action] SimState
insertFromQueue f x s@(_, ProcessorState _ psq, _) =
  case S.fromSortedList psq of
    [] -> return s
    _  -> x f s

insertFromQueueNoCompact :: Fit -> SimState -> Writer [Action] SimState
insertFromQueueNoCompact fit s = do
  a <- insertFirstFromQueue fit s
  case a of
    Nothing -> return s
    Just x  -> insertFromQueueNoCompact fit x

-- 1. Add all possible from queue according to fit
-- 2. If should compact compact and go to 1
insertFromQueueCompact :: Fit -> SimState -> Writer [Action] SimState
insertFromQueueCompact fit s@(t, ProcessorState psm psq, tis) = do
  a <- insertFirstFromQueue fit s
  case a of
    Nothing -> if shouldCompact psm (head $ S.fromSortedList psq)
      then insertFromQueueCompact
        fit
        (t, ProcessorState (compact psm) psq, tis)
      else return s
    Just x -> insertFromQueueCompact fit x

insertFirstFromQueue :: Fit -> SimState -> Writer [Action] (Maybe SimState)
insertFirstFromQueue fit (t, ProcessorState ps q, ts) = case length q of
  0 -> return Nothing
  _ -> case fit ps x of
    Just i  -> do
      a <- insertProcess ps i t x
      return $ Just (t, ProcessorState a xs, ts)
    Nothing -> return Nothing
 where
  x  = (head . S.fromSortedList) q
  xs = S.drop 1 q

removeFinishedProcesses :: SimState -> Writer [Action] SimState
removeFinishedProcesses (t, st, tis) = do
  tell $ ProcessRemoved <$> S.fromSortedList rms
  return (t, ProcessorState fps (queue st), tis)
 where
  (fps, rms) = S.partition (\x -> (t - executionStart x) < executionTime (process x))
                 (processes st)

-- Fits
bestFit :: Fit
bestFit ps p =
  fst <$> find ((>= requiredMemory p) . snd) (sortOn snd (gaps ps))

worstFit :: Fit
worstFit ps p =
  fst <$> find ((>= requiredMemory p) . snd) (sortOn (((-1) *) . snd) (gaps ps))

firstFit :: Fit
firstFit ps p = fst <$> find ((>= requiredMemory p) . snd) (gaps ps)

availableFits :: [(String, Fit)]
availableFits =
  [("Best fit", bestFit), ("Worst fit", worstFit), ("First fit", firstFit)]