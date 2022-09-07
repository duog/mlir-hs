-- Copyright 2021 Google LLC
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--      http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

module MLIR.AST where

import qualified Data.ByteString as BS

import Data.Typeable
import Data.Int
import Data.Word
import Data.Coerce
import Data.Maybe
import Data.Ix
import Data.Array.IArray
import Foreign.Ptr
import Foreign.Marshal.Alloc
import Foreign.Marshal.Array
import qualified Language.C.Inline as C
import qualified Data.ByteString.Unsafe as BS
import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Trans.Cont
import qualified Data.Map.Strict as M

import qualified MLIR.Native as Native
import qualified MLIR.Native.FFI as Native
import qualified MLIR.AST.Dialect.Affine as Affine
import MLIR.AST.Serialize
import MLIR.AST.IStorableArray

type Name = BS.ByteString
type UInt = Word

data Signedness = Signed | Unsigned | Signless
                  deriving stock (Eq, Show)
data Type =
  -- Builtin types
  -- See <https://mlir.llvm.org/docs/Dialects/Builtin/#types>
    BFloat16Type
  | Float16Type
  | Float32Type
  | Float64Type
  | Float80Type
  | Float128Type
  | ComplexType Type
  | IndexType
  | IntegerType Signedness UInt
  | TupleType [Type]
  | NoneType
  | FunctionType [Type] [Type]
  | MemRefType { memrefTypeShape :: [Maybe Int]
               , memrefTypeElement :: Type
               , memrefTypeLayout :: Maybe Attribute
               , memrefTypeMemorySpace :: Maybe Attribute }
  | RankedTensorType { rankedTensorTypeShape :: [Maybe Int]
                     , rankedTensorTypeElement :: Type
                     , rankedTensorTypeEncoding :: Maybe Attribute }
  | VectorType { vectorTypeShape :: [Int]
               , vectorTypeElement :: Type }
  | UnrankedMemRefType { unrankedMemrefTypeElement :: Type
                       , unrankedMemrefTypeMemorySpace :: Attribute }
  | UnrankedTensorType { unrankedTensorTypeElement :: Type }
  | OpaqueType { opaqueTypeNamespace :: Name
               , opaqueTypeData :: BS.ByteString }
  | MkDialectType DialectType
  deriving stock (Eq,Show)
  -- GHC cannot derive Eq due to the existential case, so we implement Eq below
  -- deriving Eq

pattern DialectType ::
  (Show t, Typeable t, Eq t, FromAST t Native.Type)
  => (Show t, Typeable t, Eq t, FromAST t Native.Type)
  => t -> Type

pattern DialectType t <- MkDialectType (WrappedDialectType (cast -> Just t))
  where DialectType t = MkDialectType (WrappedDialectType t)

data DialectType where
  WrappedDialectType :: forall t. (Show t, Typeable t, Eq t, FromAST t Native.Type) => t -> DialectType

instance Eq DialectType where
  WrappedDialectType  t == WrappedDialectType  s = fromMaybe False $ (== t) <$> cast s

instance Show DialectType where
  show (WrappedDialectType  t) = show t

data Location =
    UnknownLocation
  | FileLocation { locPath :: BS.ByteString, locLine :: UInt, locColumn :: UInt }
  | NameLocation { locName :: BS.ByteString, locChild :: Location }
  | FusedLocation { locLocations :: [Location], locMetadata :: Maybe Attribute }
  -- TODO(jpienaar): Add support C API side and implement these
  | CallSiteLocation
  | OpaqueLocation
  deriving stock Show

data Binding = Bind [Name] Operation
  deriving stock (Show)

pattern Do :: Operation -> Binding
pattern Do op = Bind [] op

pattern (:=) :: Name -> Operation -> Binding
pattern (:=) name op = Bind [name] op

pattern (::=) :: [Name] -> Operation -> Binding
pattern (::=) names op = Bind names op

data Block = Block {
    blockName :: Name
  , blockArgs :: [(Name, Type)]
  , blockBody :: [Binding]
  } deriving stock Show

data Region = Region [Block]
  deriving stock Show

data Attribute =
    ArrayAttr      [Attribute]
  | DictionaryAttr (M.Map Name Attribute)
  | FloatAttr      Type Double
  | IntegerAttr    Type Int
  | BoolAttr       Bool
  | StringAttr     BS.ByteString
  | TypeAttr       Type
  | AffineMapAttr  Affine.Map
  | UnitAttr
  | DenseArrayAttr DenseElements
  | DenseElementsAttr Type DenseElements
  | DialectAttr_ DialectAttr
  deriving stock (Eq, Show)

pattern DialectAttr ::
  (Show t, Typeable t, Eq t, FromAST t Native.Attribute)
  => (Show t, Typeable t, Eq t, FromAST t Native.Attribute)
  => t -> Attribute
pattern DialectAttr t <- DialectAttr_ (MkDialectAttr (cast -> Just t))
  where DialectAttr t = DialectAttr_ (MkDialectAttr t)

data DialectAttr where
  MkDialectAttr :: forall t. (Show t, Typeable t, Eq t, FromAST t Native.Attribute) => t -> DialectAttr

instance Eq DialectAttr where
  MkDialectAttr x == MkDialectAttr y = case cast x of
    Just x' -> x' == y
    Nothing -> False

instance Show DialectAttr where
  show (MkDialectAttr x) = show x

data DenseElements
  = forall i. (Show i, Ix i) => DenseUInt8  (IStorableArray i Word8 )
  | forall i. (Show i, Ix i) => DenseInt8   (IStorableArray i Int8  )
  | forall i. (Show i, Ix i) => DenseUInt32 (IStorableArray i Word32)
  | forall i. (Show i, Ix i) => DenseInt32  (IStorableArray i Int32 )
  | forall i. (Show i, Ix i) => DenseUInt64 (IStorableArray i Word64)
  | forall i. (Show i, Ix i) => DenseInt64  (IStorableArray i Int64 )
  | forall i. (Show i, Ix i) => DenseFloat  (IStorableArray i Float )
  | forall i. (Show i, Ix i) => DenseDouble (IStorableArray i Double)


-- Note that we use a relaxed notion of equality, where the indices don't matter!
-- TODO: Use a faster comparison? We could really just use memcmp here.
instance Eq DenseElements where
  a == b = case (a, b) of
    (DenseUInt8  da, DenseUInt8  db) -> elems da == elems db
    (DenseInt8   da, DenseInt8   db) -> elems da == elems db
    (DenseUInt32 da, DenseUInt32 db) -> elems da == elems db
    (DenseInt32  da, DenseInt32  db) -> elems da == elems db
    (DenseUInt64 da, DenseUInt64 db) -> elems da == elems db
    (DenseInt64  da, DenseInt64  db) -> elems da == elems db
    (DenseFloat  da, DenseFloat  db) -> elems da == elems db
    (DenseDouble da, DenseDouble db) -> elems da == elems db
    _ -> False

instance Show DenseElements where
  showsPrec d = \case
    DenseUInt8 x -> showParen (d >= 10) (showString "DenseUInt8") . shows x
    DenseInt8 x -> showParen (d >= 10) (showString "DenseUInt8" ). shows x
    DenseUInt32 x -> showParen (d >= 10) (showString "DenseUInt8" ). shows x
    DenseInt32  x -> showParen (d >= 10) (showString "DenseUInt8" ). shows x
    DenseUInt64  x -> showParen (d >= 10) (showString "DenseUInt8" ). shows x
    DenseInt64 x -> showParen (d >= 10) (showString "DenseUInt8" ). shows x
    DenseFloat x -> showParen (d >= 10) (showString "DenseUInt8" ). shows x
    DenseDouble x -> showParen (d >= 10) (showString "DenseUInt8" ). shows x


data ResultTypes = Explicit [Type] | Inferred
  deriving stock Show

type NamedAttributes = M.Map Name Attribute

data AbstractOperation operand = Operation {
    opName :: Name,
    opLocation :: Location,
    opResultTypes :: ResultTypes,
    opOperands :: [operand],
    opRegions :: [Region],
    opSuccessors :: [Name],
    opAttributes :: M.Map Name Attribute
  } deriving stock Show
type Operation = AbstractOperation Name

--------------------------------------------------------------------------------
-- Builtin operations

pattern NoAttrs :: M.Map Name Attribute
pattern NoAttrs <- _  -- Accept any attributes
  where NoAttrs  = M.empty

namedAttribute :: Name -> Attribute -> NamedAttributes
namedAttribute name value = M.singleton name value

pattern ModuleOp :: Block -> Operation
pattern ModuleOp body = Operation
  { opName = "builtin.module"
  , opLocation = UnknownLocation
  , opResultTypes = Explicit []
  , opOperands = []
  , opRegions = [Region [body]]
  , opSuccessors = []
  , opAttributes = NoAttrs
  }

pattern FuncAttrs :: Name -> Type -> M.Map Name Attribute
pattern FuncAttrs name ty <-
  ((\d -> (M.lookup "sym_name" d, M.lookup "type" d)) ->
   (Just (StringAttr name), Just (TypeAttr ty)))
  where FuncAttrs name ty = M.fromList [("sym_name", StringAttr name),
                                        ("function_type", TypeAttr ty)]

pattern FuncOp :: Location -> Name -> Type -> Region -> Operation
pattern FuncOp loc name ty body = Operation
  { opName = "func.func"
  , opLocation = loc
  , opResultTypes = Explicit []
  , opOperands = []
  , opRegions = [body]
  , opSuccessors = []
  , opAttributes = FuncAttrs name ty
  }

--------------------------------------------------------------------------------
-- AST -> Native translation

C.context $ C.baseCtx <> Native.mlirCtx

C.include "<stdalign.h>"
C.include "mlir-c/IR.h"
C.include "mlir-c/BuiltinTypes.h"
C.include "mlir-c/BuiltinAttributes.h"

instance FromAST Location Native.Location where
  fromAST ctx env loc = case loc of
    UnknownLocation -> Native.getUnknownLocation ctx
    FileLocation file line col -> do
      Native.withStringRef file \fileStrRef ->
        Native.getFileLineColLocation ctx fileStrRef cline ccol
          where cline = fromIntegral line
                ccol = fromIntegral col
    FusedLocation locLocations locMetadata -> do
      metadata <- case locMetadata of
        -- TODO: Consider factoring out to convenience function.
        Nothing -> [C.exp| MlirAttribute { mlirAttributeGetNull() } |]
        Just l -> fromAST ctx env l
      evalContT $ do
        (numLocs, locs) <- packFromAST ctx env locLocations
        liftIO $ [C.exp| MlirLocation {
          mlirLocationFusedGet($(MlirContext ctx),
            $(intptr_t numLocs), $(MlirLocation* locs),
            $(MlirAttribute metadata))
        } |]
    NameLocation name childLoc -> do
      Native.withStringRef name \nameStrRef -> do
        nativeChildLoc <- fromAST ctx env childLoc
        Native.getNameLocation ctx nameStrRef nativeChildLoc
    -- TODO(jpienaar): Fix
    _ -> error "Unimplemented Location case"

instance FromAST Type Native.Type where
  fromAST ctx env ty = case ty of
    BFloat16Type  -> [C.exp| MlirType { mlirBF16TypeGet($(MlirContext ctx)) } |]
    Float16Type   -> [C.exp| MlirType { mlirF16TypeGet($(MlirContext ctx)) } |]
    Float32Type   -> [C.exp| MlirType { mlirF32TypeGet($(MlirContext ctx)) } |]
    Float64Type   -> [C.exp| MlirType { mlirF64TypeGet($(MlirContext ctx)) } |]
    Float80Type   -> error "Float80Type missing in the MLIR C API!"
    Float128Type  -> error "Float128Type missing in the MLIR C API!"
    ComplexType e -> do
      ne <- fromAST ctx env e
      [C.exp| MlirType { mlirComplexTypeGet($(MlirType ne)) } |]
    FunctionType args rets -> evalContT $ do
      (numArgs, nativeArgs) <- packFromAST ctx env args
      (numRets, nativeRets) <- packFromAST ctx env rets
      liftIO $ [C.exp| MlirType {
        mlirFunctionTypeGet($(MlirContext ctx),
                            $(intptr_t numArgs), $(MlirType* nativeArgs),
                            $(intptr_t numRets), $(MlirType* nativeRets))
      } |]
    IndexType -> [C.exp| MlirType { mlirIndexTypeGet($(MlirContext ctx)) } |]
    IntegerType signedness width -> case signedness of
      Signless -> [C.exp| MlirType {
        mlirIntegerTypeGet($(MlirContext ctx), $(unsigned int cwidth))
      } |]
      Signed -> [C.exp| MlirType {
        mlirIntegerTypeSignedGet($(MlirContext ctx), $(unsigned int cwidth))
      } |]
      Unsigned -> [C.exp| MlirType {
        mlirIntegerTypeUnsignedGet($(MlirContext ctx), $(unsigned int cwidth))
      } |]
      where cwidth = fromIntegral width
    MemRefType shape elTy layout memSpace -> evalContT $ do
      (rank, nativeShape) <- packArray shapeI64
      liftIO $ do
        nativeElTy <- fromAST ctx env elTy
        nativeSpace <- case memSpace of
          Just space -> fromAST ctx env space
          Nothing    -> return $ coerce nullPtr
        nativeLayout <- case layout of
          Just alayout -> fromAST ctx env alayout
          Nothing      -> return $ coerce nullPtr
        [C.exp| MlirType {
          mlirMemRefTypeGet($(MlirType nativeElTy),
                            $(intptr_t rank), $(int64_t* nativeShape),
                            $(MlirAttribute nativeLayout), $(MlirAttribute nativeSpace))
        } |]
      where shapeI64 = fmap (maybe (-1) fromIntegral) shape :: [Int64]
    NoneType -> [C.exp| MlirType { mlirNoneTypeGet($(MlirContext ctx)) } |]
    OpaqueType _ _ -> notImplemented
    RankedTensorType shape elTy encoding -> evalContT $ do
      (rank, nativeShape) <- packArray shapeI64
      liftIO $ do
        nativeElTy <- fromAST ctx env elTy
        nativeEncoding <- case encoding of
          Just enc -> fromAST ctx env enc
          Nothing  -> return $ coerce nullPtr
        [C.exp| MlirType {
          mlirRankedTensorTypeGet($(intptr_t rank), $(int64_t* nativeShape),
                                  $(MlirType nativeElTy), $(MlirAttribute nativeEncoding))
        } |]
      where shapeI64 = fmap (maybe (-1) fromIntegral) shape :: [Int64]
    TupleType tys -> evalContT $ do
      (numTypes, nativeTypes) <- packFromAST ctx env tys
      liftIO $ [C.exp| MlirType {
        mlirTupleTypeGet($(MlirContext ctx), $(intptr_t numTypes), $(MlirType* nativeTypes))
      } |]
    UnrankedMemRefType elTy attr -> do
      nativeElTy <- fromAST ctx env elTy
      nativeAttr <- fromAST ctx env attr
      [C.exp| MlirType {
        mlirUnrankedMemRefTypeGet($(MlirType nativeElTy), $(MlirAttribute nativeAttr))
      } |]
    UnrankedTensorType elTy -> do
      nativeElTy <- fromAST ctx env elTy
      [C.exp| MlirType {
        mlirUnrankedTensorTypeGet($(MlirType nativeElTy))
      } |]
    VectorType shape elTy -> evalContT $ do
      (rank, nativeShape) <- packArray shapeI64
      liftIO $ do
        nativeElTy <- fromAST ctx env elTy
        [C.exp| MlirType {
          mlirVectorTypeGet($(intptr_t rank), $(int64_t* nativeShape), $(MlirType nativeElTy))
        } |]
      where shapeI64 = fmap fromIntegral shape :: [Int64]
    MkDialectType (WrappedDialectType t) -> fromAST ctx env t


instance FromAST Region Native.Region where
  fromAST ctx env@(valueEnv, _) (Region blocks) = do
    region   <- [C.exp| MlirRegion { mlirRegionCreate() } |]
    blockEnv <- foldM (initAppendBlock region) mempty blocks
    mapM_ (fromAST ctx (valueEnv, blockEnv)) blocks
    return region
    where
      initAppendBlock :: Native.Region -> BlockMapping -> Block -> IO BlockMapping
      initAppendBlock region blockEnv block = do
        nativeBlock <- initBlock block
        [C.exp| void {
          mlirRegionAppendOwnedBlock($(MlirRegion region), $(MlirBlock nativeBlock))
        } |]
        return $ blockEnv <> (M.singleton (blockName block) nativeBlock)

      initBlock :: Block -> IO Native.Block
      initBlock Block{..} = do
        -- TODO: Use proper locations
        let locations = take (length blockArgs) (repeat UnknownLocation)
        evalContT $ do
          let blockArgTypes = snd <$> blockArgs
          (numBlockArgs, nativeArgTypes) <- packFromAST ctx env blockArgTypes
          (_, locs) <- packFromAST ctx env locations
          liftIO $ [C.exp| MlirBlock {
            mlirBlockCreate($(intptr_t numBlockArgs), $(MlirType* nativeArgTypes), $(MlirLocation* locs))
          } |]


instance FromAST Block Native.Block where
  fromAST ctx (outerValueEnv, blockEnv) Block{..} = do
    let block = fromMaybe (error "dougrulz1") $ M.lookup blockName blockEnv
    nativeBlockArgs <- getBlockArgs block
    let blockArgNames = fst <$> blockArgs
    let argValueEnv = M.fromList $ zip blockArgNames nativeBlockArgs
    foldM_ (appendInstr block) (outerValueEnv <> argValueEnv) blockBody
    return block
    where
      appendInstr :: Native.Block -> ValueMapping -> Binding -> IO ValueMapping
      appendInstr block valueEnv (Bind names operation) = do
        nativeOperation <- fromAST ctx (valueEnv, blockEnv) operation
        [C.exp| void {
          mlirBlockAppendOwnedOperation($(MlirBlock block),
                                        $(MlirOperation nativeOperation))
        } |]
        nativeResults <- getOperationResults nativeOperation
        return $ valueEnv <> (M.fromList $ zip names nativeResults)

      getBlockArgs :: Native.Block -> IO [Native.Value]
      getBlockArgs block = do
        numArgs <- [C.exp| intptr_t { mlirBlockGetNumArguments($(MlirBlock block)) } |]
        allocaArray (fromIntegral numArgs) \nativeArgs -> do
          [C.block| void {
            for (intptr_t i = 0; i < $(intptr_t numArgs); ++i) {
              $(MlirValue* nativeArgs)[i] = mlirBlockGetArgument($(MlirBlock block), i);
            }
          } |]
          unpackArray numArgs nativeArgs

      getOperationResults :: Native.Operation -> IO [Native.Value]
      getOperationResults op = do
        numResults <- [C.exp| intptr_t { mlirOperationGetNumResults($(MlirOperation op)) } |]
        allocaArray (fromIntegral numResults) \nativeResults -> do
          [C.block| void {
            for (intptr_t i = 0; i < $(intptr_t numResults); ++i) {
              $(MlirValue* nativeResults)[i] = mlirOperationGetResult($(MlirOperation op), i);
            }
          } |]
          unpackArray numResults nativeResults


instance FromAST Attribute Native.Attribute where
  fromAST ctx env attr = case attr of
    DialectAttr_ (MkDialectAttr a) -> fromAST ctx env a
    ArrayAttr attrs -> evalContT $ do
      (numAttrs, nativeAttrs) <- packFromAST ctx env attrs
      liftIO $ [C.exp| MlirAttribute {
        mlirArrayAttrGet($(MlirContext ctx), $(intptr_t numAttrs), $(MlirAttribute* nativeAttrs))
      } |]
    DictionaryAttr dict -> evalContT $ do
      (numAttrs, nativeAttrs) <- packNamedAttrs ctx env dict
      liftIO $ [C.exp| MlirAttribute {
        mlirDictionaryAttrGet($(MlirContext ctx), $(intptr_t numAttrs), $(MlirNamedAttribute* nativeAttrs))
      } |]
    FloatAttr ty value -> do
      nativeType <- fromAST ctx env ty
      let nativeValue = coerce value
      [C.exp| MlirAttribute {
        mlirFloatAttrDoubleGet($(MlirContext ctx), $(MlirType nativeType), $(double nativeValue))
      } |]
    IntegerAttr ty value -> do
      nativeType <- fromAST ctx env ty
      let nativeValue = fromIntegral value
      [C.exp| MlirAttribute {
        mlirIntegerAttrGet($(MlirType nativeType), $(int64_t nativeValue))
      } |]
    BoolAttr value -> do
      let nativeValue = if value then 1 else 0
      [C.exp| MlirAttribute {
        mlirBoolAttrGet($(MlirContext ctx), $(int nativeValue))
      } |]
    StringAttr value -> do
      Native.withStringRef value \(Native.StringRef ptr len) ->
        [C.exp| MlirAttribute {
          mlirStringAttrGet($(MlirContext ctx), (MlirStringRef){$(char* ptr), $(size_t len)})
        } |]
    TypeAttr ty -> do
      nativeType <- fromAST ctx env ty
      [C.exp| MlirAttribute { mlirTypeAttrGet($(MlirType nativeType)) } |]
    AffineMapAttr afMap -> do
      nativeMap <- fromAST ctx env afMap
      [C.exp| MlirAttribute { mlirAffineMapAttrGet($(MlirAffineMap nativeMap)) } |]
    UnitAttr -> [C.exp| MlirAttribute { mlirUnitAttrGet($(MlirContext ctx)) } |]
    DenseArrayAttr storage -> do
      case storage of
        -- TODO(jpienaar): Update once unsigned is supported.
        DenseUInt8 arr -> do
          let size = fromIntegral $ rangeSize $ bounds arr
          unsafeWithIStorableArray arr \valuesPtr ->
            [C.exp| MlirAttribute {
              mlirDenseI8ArrayGet($(MlirContext ctx), $(intptr_t size),
                                           $(const uint8_t* valuesPtr))
            } |]
        DenseInt8 arr -> do
          let size = fromIntegral $ rangeSize $ bounds arr
          unsafeWithIStorableArray arr \valuesPtr ->
            [C.exp| MlirAttribute {
              mlirDenseI8ArrayGet($(MlirContext ctx), $(intptr_t size),
                                           $(const int8_t* valuesPtr))
            } |]
        -- TODO(jpienaar): Update once unsigned is supported.
        DenseUInt32 arr -> do
          let size = fromIntegral $ rangeSize $ bounds arr
          unsafeWithIStorableArray arr \valuesPtr ->
            [C.exp| MlirAttribute {
              mlirDenseI32ArrayGet($(MlirContext ctx), $(intptr_t size),
                                            $(const uint32_t* valuesPtr))
            } |]
        DenseInt32 arr -> do
          let size = fromIntegral $ rangeSize $ bounds arr
          unsafeWithIStorableArray arr \valuesPtr ->
            [C.exp| MlirAttribute {
              mlirDenseI32ArrayGet($(MlirContext ctx), $(intptr_t size),
                                            $(const int32_t* valuesPtr))
            } |]
        -- TODO(jpienaar): Update once unsigned is supported.
        DenseUInt64 arr -> do
          let size = fromIntegral $ rangeSize $ bounds arr
          unsafeWithIStorableArray arr \valuesPtr ->
            [C.exp| MlirAttribute {
              mlirDenseI64ArrayGet($(MlirContext ctx), $(intptr_t size),
                                            $(const uint64_t* valuesPtr))
            } |]
        DenseInt64 arr -> do
          let size = fromIntegral $ rangeSize $ bounds arr
          unsafeWithIStorableArray arr \valuesPtr ->
            [C.exp| MlirAttribute {
              mlirDenseI64ArrayGet($(MlirContext ctx), $(intptr_t size),
                                            $(const int64_t* valuesPtr))
            } |]
        DenseFloat arr -> do
          let size = fromIntegral $ rangeSize $ bounds arr
          unsafeWithIStorableArray arr \valuesPtrHs -> do
            let valuesPtr = castPtr valuesPtrHs
            [C.exp| MlirAttribute {
              mlirDenseF32ArrayGet($(MlirContext ctx), $(intptr_t size),
                                            $(const float* valuesPtr))
            } |]
        DenseDouble arr -> do
          let size = fromIntegral $ rangeSize $ bounds arr
          unsafeWithIStorableArray arr \valuesPtrHs -> do
            let valuesPtr = castPtr valuesPtrHs
            [C.exp| MlirAttribute {
              mlirDenseF64ArrayGet($(MlirContext ctx), $(intptr_t size),
                                             $(const double* valuesPtr))
            } |]
    DenseElementsAttr ty storage -> do
      nativeType <- fromAST ctx env ty
      case storage of
        DenseUInt8  arr -> do
          let size = fromIntegral $ rangeSize $ bounds arr
          unsafeWithIStorableArray arr \valuesPtr ->
            [C.exp| MlirAttribute {
              mlirDenseElementsAttrUInt8Get($(MlirType nativeType), $(intptr_t size),
                                            $(const uint8_t* valuesPtr))
            } |]
        DenseInt8   arr -> do
          let size = fromIntegral $ rangeSize $ bounds arr
          unsafeWithIStorableArray arr \valuesPtr ->
            [C.exp| MlirAttribute {
              mlirDenseElementsAttrInt8Get($(MlirType nativeType), $(intptr_t size),
                                           $(const int8_t* valuesPtr))
            } |]
        DenseUInt32 arr -> do
          let size = fromIntegral $ rangeSize $ bounds arr
          unsafeWithIStorableArray arr \valuesPtr ->
            [C.exp| MlirAttribute {
              mlirDenseElementsAttrUInt32Get($(MlirType nativeType), $(intptr_t size),
                                             $(const uint32_t* valuesPtr))
            } |]
        DenseInt32  arr -> do
          let size = fromIntegral $ rangeSize $ bounds arr
          unsafeWithIStorableArray arr \valuesPtr ->
            [C.exp| MlirAttribute {
              mlirDenseElementsAttrInt32Get($(MlirType nativeType), $(intptr_t size),
                                            $(const int32_t* valuesPtr))
            } |]
        DenseUInt64 arr -> do
          let size = fromIntegral $ rangeSize $ bounds arr
          unsafeWithIStorableArray arr \valuesPtr ->
            [C.exp| MlirAttribute {
              mlirDenseElementsAttrUInt64Get($(MlirType nativeType), $(intptr_t size),
                                             $(const uint64_t* valuesPtr))
            } |]
        DenseInt64  arr -> do
          let size = fromIntegral $ rangeSize $ bounds arr
          unsafeWithIStorableArray arr \valuesPtr ->
            [C.exp| MlirAttribute {
              mlirDenseElementsAttrInt64Get($(MlirType nativeType), $(intptr_t size),
                                            $(const int64_t* valuesPtr))
            } |]
        DenseFloat arr -> do
          let size = fromIntegral $ rangeSize $ bounds arr
          unsafeWithIStorableArray arr \valuesPtrHs -> do
            let valuesPtr = castPtr valuesPtrHs
            [C.exp| MlirAttribute {
              mlirDenseElementsAttrFloatGet($(MlirType nativeType), $(intptr_t size),
                                            $(const float* valuesPtr))
            } |]
        DenseDouble arr -> do
          let size = fromIntegral $ rangeSize $ bounds arr
          unsafeWithIStorableArray arr \valuesPtrHs -> do
            let valuesPtr = castPtr valuesPtrHs
            [C.exp| MlirAttribute {
              mlirDenseElementsAttrDoubleGet($(MlirType nativeType), $(intptr_t size),
                                             $(const double* valuesPtr))
            } |]


instance FromAST Operation Native.Operation where
  fromAST ctx env@(valueEnv, blockEnv) o@Operation{..} = evalContT $ do
    (namePtr, nameLen) <- ContT $ BS.unsafeUseAsCStringLen opName
    let nameLenSizeT = fromIntegral nameLen
    (infersResults, (numResultTypes, nativeResultTypes)) <- case opResultTypes of
      Inferred -> return (CTrue, (0, nullPtr))
      Explicit types -> (CFalse,) <$> packFromAST ctx env types
    nativeLocation <- liftIO $ fromAST ctx env opLocation
    let
      do_dump :: forall a. String -> Name -> IO a
      do_dump s n = do
        putStrLn $ "dump " <> s <> show n
        print o
        pure $ error $ "do_dump:" <> s <> show n

      val_lookup (n :: Name) = maybe (do_dump "val_lookup" n) pure $ M.lookup n valueEnv
      block_lookup (n :: Name) = maybe (do_dump "dougrulz3" n) pure $ M.lookup n blockEnv
    (numOperands, nativeOperands) <- packArray =<<  liftIO (traverse val_lookup opOperands)
    (numRegions, nativeRegions) <- packFromAST ctx env opRegions
    (numSuccessors, nativeSuccessors) <- packArray =<< (liftIO $ traverse block_lookup opSuccessors)
    (numAttributes, nativeAttributes) <- packNamedAttrs ctx env opAttributes
    -- NB: This is nullable when result type inference is enabled
    maybeOperation <- liftIO $ Native.nullable <$> [C.block| MlirOperation {
      MlirOperationState state = mlirOperationStateGet(
        (MlirStringRef){$(char* namePtr), $(size_t nameLenSizeT)},
        $(MlirLocation nativeLocation));
      if ($(bool infersResults)) {
        mlirOperationStateEnableResultTypeInference(&state);
      } else {
        mlirOperationStateAddResults(
            &state, $(intptr_t numResultTypes), $(MlirType* nativeResultTypes));
      }
      mlirOperationStateAddOperands(
          &state, $(intptr_t numOperands), $(MlirValue* nativeOperands));
      mlirOperationStateAddOwnedRegions(
          &state, $(intptr_t numRegions), $(MlirRegion* nativeRegions));
      mlirOperationStateAddSuccessors(
          &state, $(intptr_t numSuccessors), $(MlirBlock* nativeSuccessors));
      mlirOperationStateAddAttributes(
          &state, $(intptr_t numAttributes), $(MlirNamedAttribute* nativeAttributes));
      return mlirOperationCreate(&state);
    } |]
    case maybeOperation of
      Just operation -> return operation
      Nothing -> error $ "Type inference failed for operation " ++ show opName

--------------------------------------------------------------------------------
-- Utilities for AST -> Native translation

packNamedAttrs :: Native.Context -> ValueAndBlockMapping
               -> M.Map Name Attribute -> ContT r IO (C.CIntPtr, Ptr Native.NamedAttribute)
packNamedAttrs ctx env attrDict = do
  let arrSize = M.size attrDict
  elemSize  <- liftIO $ fromIntegral <$> [C.exp| size_t { sizeof(MlirNamedAttribute) } |]
  elemAlign <- liftIO $ fromIntegral <$> [C.exp| size_t { alignof(MlirNamedAttribute) } |]
  ptr <- ContT $ allocaBytesAligned (arrSize * elemSize) (elemAlign)
  flip mapM_ (zip [0..] $ M.toList attrDict) \(i, (name, attr)) -> do
    nameRef <- ContT $ Native.withStringRef name
    liftIO $ do
      nativeAttr <- fromAST ctx env attr
      ident <- Native.createIdentifier ctx nameRef
      [C.exp| void {
        $(MlirNamedAttribute* ptr)[$(int i)] =
          mlirNamedAttributeGet($(MlirIdentifier ident), $(MlirAttribute nativeAttr));
      } |]
  return (fromIntegral arrSize, ptr)

pattern CTrue :: C.CBool
pattern CTrue = C.CBool 1

pattern CFalse :: C.CBool
pattern CFalse = C.CBool 0

notImplemented :: forall a. a
notImplemented = error "Not implemented"
