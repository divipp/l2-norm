----- optimized version of L2Slow.hs -----
--
-- Optimizations:
--  - vector norms are cached
--  - not all submatrix norms are calculated
--  - parallel execution
--
-- Other improvements:
--  - print the witness partition

import Control.Concurrent
import Control.Monad
import Control.Monad.Par.IO
import Control.Monad.IO.Class
import Control.Monad.Par.Class
import Data.IORef
import Data.Maybe
import qualified Data.Vector.Unboxed as V
import Options.Applicative


type Vec = V.Vector Int

{-# INLINE zero #-}
zero :: Vec -> Vec
zero v = V.replicate (V.length v) 0

(.+.) :: Vec -> Vec -> Vec
a .+. b = V.zipWith (+) a b

type Norm1 = Int

norm1 :: Vec -> Norm1
norm1 v = V.sum (V.map abs v)

type VecWithNorm = (Vec, Norm1)

withNorm1 :: Vec -> VecWithNorm
withNorm1 v = (v, norm1 v)

type L2Norm = Int
type Witness = [Bool]
type L2Witness = (L2Norm, Witness)

{-# INLINE maxWitness #-}
maxWitness :: L2Witness -> L2Witness -> L2Witness
maxWitness w1 w2 = if fst w1 < fst w2 then w2 else w1

{-# INLINE maxWitness' #-}
maxWitness' q1@(i1, w1) q2@(i2, w2) = case compare i1 i2 of
  LT -> q2
  GT -> q1
  EQ -> case w1 of [] -> q2; _ -> q1

type Mat = [Vec]
type MatWithNorms = [(L2Norm, Vec)]

f :: Witness -> VecWithNorm -> VecWithNorm -> MatWithNorms -> L2Witness -> L2Witness
f w (va, na) (vb, nb) m i = case m of
  [] -> maxWitness (na + nb, w) i
  (n, v): m'
    | fst i >= n + na + nb -> i
    | otherwise -> f (False: w) (withNorm1(v .+. va)) (vb, nb) m' (f (True: w) (va, na) (withNorm1(v .+. vb)) m' i)

fPar :: IORef L2Norm -> Witness -> VecWithNorm -> VecWithNorm -> MatWithNorms -> ParIO L2Witness
fPar best w (va, na) (vb, nb) m = case m of
  (n, v): m' | n == maxBound -> do
    c1 <- spawn (fPar best (False: w) (withNorm1 $ v .+. va) (vb, nb) m')
    c2 <- spawn (fPar best (True:  w) (va, na) (withNorm1 (v .+. vb)) m')
    liftM2 maxWitness' (get c1) (get c2)
  _ -> do
    i <- liftIO $ readIORef best
    let i' = f w (va, na) (vb, nb) m (i, [])
        fi = fst i'
    fi `seq` liftIO (atomicModifyIORef best (\i -> (max fi i, ())))
    pure i'

{-# INLINE f' #-}
f' :: L2Norm -> Vec -> MatWithNorms -> IO L2Witness
f' guess v vs = do
  best <- newIORef guess
  runParIO $ fPar best [True] (withNorm1 (zero v)) (withNorm1 v) vs

g :: Int -> Mat -> IO MatWithNorms
g _ [] = pure []
g l (v: vs) = do
  m <- g (l-1) vs
  let m' = zipWith (\i (a, b) -> (if i < (length vs + 1) `div` 4 then maxBound else a, b)) [0..] m
  i <- if l > 0 then pure maxBound else fst <$> f' 0 v m'
  pure ((i, v): m)

l2 :: L2Norm -> Mat -> IO L2Witness
l2 guess (v:vs) = do
  m <- g ((length vs + 1) `div` 4) vs
  f' guess v m

compute :: L2Norm -> String -> IO ()
compute guess f = do
  s <- readFile f
  let m = (map (V.fromList . map read . words) . takeWhile (not . null) . lines) s
  (i, w) <- l2 guess m
  let
    -- `norm` is redifined here for better compiler optimizations
    norm l = V.sum (V.map abs (foldl (V.zipWith (+)) (V.replicate (V.length (head m)) 0) l))
    rows = zip (reverse w) m
    j = norm [r | (True, r) <- rows] + norm [r | (False, r) <- rows]

  putStr $ unlines $ if i == j then
      [ "Row numbers in the two partitions:"
      , "  Partition A:  " ++ unwords [show i ++ "." | (True, i) <- zip (reverse w) [1..]]
      , "  Partition B:  " ++ unwords [show i ++ "." | (False, i) <- zip (reverse w) [1..]]
      , "L2 norm:"
      , "  " ++ show j
      ]
    else
      [ "!!! ERROR !!!"
      , "Computed L2 norm:"
      , "  " ++ show i
      , "Recalculated L2 norm:"
      , "  " ++ show j
      ]

main :: IO ()
main = join (execParser opts)
 where
    opts = info (helper <*> options)
      ( fullDesc
     <> progDesc "Partition the rows of a matrix in two disjoint sets A and B such that |sum A| + |sum B| is maximal, where |.| is the Manhattan norm."
      )

    options :: Parser (IO ())
    options = compute
      <$> (fromMaybe 0 <$> optional (option auto $ short 'g' <> long "guessed" <> metavar "NAT" <> help "guessed result - default is 0" <> completeWith ["0"]))
      <*> (argument str (metavar "FILE" <> action "filename"))
