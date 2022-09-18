{-# language CPP #-}

import System.Process
import System.Environment
import System.Directory
import System.FilePath

llvmIncludeRoot :: FilePath
llvmIncludeRoot = LLVM_INCLUDE_DIR

main :: IO ()
main = do
  _srcFile : _inFile : outFile : rest <- getArgs
  createDirectoryIfMissing True $ takeDirectory outFile
  setCurrentDirectory $ llvmIncludeRoot
  callProcess "mlir-hs-tblgen" $  "-o" : outFile : rest

  -- let process = proc "mlir-hs-tblgen"$  "-o" : outFile : rest
  -- withCreateProcess process (\_ _ _ h -> waitForProcess h) >>= exitWith
