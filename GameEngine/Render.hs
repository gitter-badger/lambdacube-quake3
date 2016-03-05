{-# LANGUAGE OverloadedStrings, RecordWildCards, ViewPatterns #-}
module GameEngine.Render where

import Control.Applicative
import Control.Monad
import Data.ByteString.Char8 (ByteString)
import Data.Vect.Float
import Data.List
import Foreign
import Data.Map (Map)
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Data.Vector as V
import qualified Data.Vector.Storable.Mutable as SMV
import qualified Data.Vector.Storable as SV
import qualified Data.ByteString as SB
import qualified Data.ByteString.Char8 as SB8
import Codec.Picture
import Debug.Trace
import System.FilePath

import LambdaCube.GL
import LambdaCube.GL.Mesh
import GameEngine.BSP
import GameEngine.MD3 (MD3Model)
import qualified GameEngine.MD3 as MD3
import GameEngine.Q3Patch

{-
    plans:
        - proper render of q3 objects
        - shadow mapping
        - bloom
        - ssao
-}

tessellatePatch :: V.Vector DrawVertex -> Surface -> Int -> (V.Vector DrawVertex,V.Vector Int)
tessellatePatch drawV sf level = (V.concat vl,V.concat il)
  where
    (w,h)   = srPatchSize sf
    gridF :: [DrawVertex] -> [[DrawVertex]]
    gridF l = case splitAt w l of
        (x,[])  -> [x]
        (x,xs)  -> x:gridF xs
    grid        = gridF $ V.toList $ V.take (srNumVertices sf) $ V.drop (srFirstVertex sf) drawV
    controls    = [V.fromList $ concat [take 3 $ drop x l | l <- lines] | x <- [0,2..w-3], y <- [0,2..h-3], let lines = take 3 $ drop y grid]
    patches     = [tessellate c level | c <- controls]
    (vl,il)     = unzip $ reverse $ snd $ foldl' (\(o,l) (v,i) -> (o+V.length v, (v,V.map (+o) i):l)) (0,[]) patches

addObject' :: GLStorage -> String -> Primitive -> Maybe (IndexStream Buffer) -> Map String (Stream Buffer) -> [String] -> IO Object
addObject' rndr name prim idx attrs unis = addObject rndr name' prim idx attrs' unis
  where
    attrs'  = Map.filterWithKey (\n _ -> elem n renderAttrs) attrs
    setters = objectArrays . schema $ rndr
    alias   = dropExtension name
    name'
      | Map.member name setters = name
      | Map.member alias setters = alias
      | otherwise = "missing shader"
    renderAttrs = Map.keys $ case Map.lookup name' setters of
        Just (ObjectArraySchema _ x)  -> x
        _           -> error $ "material not found: " ++ show name'

addBSP :: GLStorage -> BSPLevel -> IO (V.Vector [Object])
addBSP renderer BSPLevel{..} = do
    let byteStringToVector :: SB.ByteString -> SV.Vector Word8
        byteStringToVector = SV.fromList . SB.unpack
    lightMapTextures <- fmap V.fromList $ forM (V.toList blLightmaps) $ \(Lightmap d) -> do
        uploadTexture2DToGPU' True False True True $ ImageRGB8 $ Image 128 128 $ byteStringToVector d
    whiteTex <- uploadTexture2DToGPU' False False False False $ ImageRGB8 $ generateImage (\_ _ -> PixelRGB8 255 255 255) 1 1

    -- construct vertex and index buffer
    let lightMapTexturesSize = V.length lightMapTextures
        convertSurface (objs,lenV,arrV,lenI,arrI) sf = if noDraw then skip else case srSurfaceType sf of
            Planar          -> objs'
            TriangleSoup    -> objs'
            -- tessellate, concatenate vertex and index data to fixed vertex and index buffer
            Patch           -> ((lmIdx, lenV, lenV', lenI, lenI', TriangleStrip, name):objs, lenV+lenV', v:arrV, lenI+lenI', i:arrI)
              where
                (v,i) = tessellatePatch blDrawVertices sf 5
                lenV' = V.length v
                lenI' = V.length i
            Flare           -> skip
          where
            lmIdx = srLightmapNum sf
            skip  = ((lmIdx,srFirstVertex sf, srNumVertices sf, srFirstIndex sf, 0, TriangleList, name):objs, lenV, arrV, lenI, arrI)
            objs' = ((lmIdx,srFirstVertex sf, srNumVertices sf, srFirstIndex sf, srNumIndices sf, TriangleList, name):objs, lenV, arrV, lenI, arrI)
            Shader name sfFlags _ = blShaders V.! (srShaderNum sf)
            noDraw = sfFlags .&. 0x80 /= 0
        (objs,_,drawVl,_,drawIl) = V.foldl' convertSurface ([],V.length blDrawVertices,[blDrawVertices],V.length blDrawIndices,[blDrawIndices]) blSurfaces
        drawV' = V.concat $ reverse drawVl
        drawI' = V.concat $ reverse drawIl

        withV w a f = w a (\p -> f $ castPtr p)
        attribute f = withV SV.unsafeWith $ SV.convert $ V.map f drawV'
        indices     = SV.convert $ V.map fromIntegral drawI' :: SV.Vector Word32
        vertexCount = V.length drawV'

    vertexBuffer <- compileBuffer $
        [ Array ArrFloat (3 * vertexCount) $ attribute dvPosition
        , Array ArrFloat (2 * vertexCount) $ attribute dvDiffuseUV
        , Array ArrFloat (2 * vertexCount) $ attribute dvLightmaptUV
        , Array ArrFloat (3 * vertexCount) $ attribute dvNormal
        , Array ArrFloat (4 * vertexCount) $ attribute dvColor
        ]
    indexBuffer <- compileBuffer [Array ArrWord32 (SV.length indices) $ withV SV.unsafeWith indices]
    -- add to storage
    let obj surfaceIdx (lmIdx,startV,countV,startI,countI,prim,SB8.unpack -> name) = do
            let attrs = Map.fromList $
                    [ ("position",      Stream Attribute_V3F vertexBuffer 0 startV countV)
                    , ("diffuseUV",     Stream Attribute_V2F vertexBuffer 1 startV countV)
                    , ("lightmapUV",    Stream Attribute_V2F vertexBuffer 2 startV countV)
                    , ("normal",        Stream Attribute_V3F vertexBuffer 3 startV countV)
                    , ("color",         Stream Attribute_V4F vertexBuffer 4 startV countV)
                    ]
                index = IndexStream indexBuffer 0 startI countI
                isValidIdx i = i >= 0 && i < lightMapTexturesSize
                objUnis = ["LightMap","worldMat"]
            o <- addObject' renderer name prim (Just index) attrs objUnis
            o1 <- addObject renderer "LightMapOnly" prim (Just index) attrs objUnis
            let lightMap a = forM_ [o,o1] $ \b -> uniformFTexture2D "LightMap" (objectUniformSetter b) a
            {-
                #define LIGHTMAP_2D			-4		// shader is for 2D rendering
                #define LIGHTMAP_BY_VERTEX	-3		// pre-lit triangle models
                #define LIGHTMAP_WHITEIMAGE	-2
                #define	LIGHTMAP_NONE		-1
            -}
            case isValidIdx lmIdx of
                False   -> lightMap whiteTex
                True    -> lightMap $ lightMapTextures V.! lmIdx
            return [o,o1]
    V.imapM obj $ V.fromList $ reverse objs

data LCMD3
    = LCMD3
    { lcmd3Object   :: [Object]
    , lcmd3Buffer   :: Buffer
    , lcmd3Frames   :: V.Vector [(Int,Array)]
    }

setMD3Frame :: LCMD3 -> Int -> IO ()
setMD3Frame (LCMD3{..}) idx = updateBuffer lcmd3Buffer $ lcmd3Frames V.! idx

type MD3Skin = Map String String

addMD3 :: GLStorage -> MD3Model -> MD3Skin -> [String] -> IO LCMD3
addMD3 r model skin unis = do
    let cvtSurface :: MD3.Surface -> (Array,Array,V.Vector (Array,Array))
        cvtSurface sf = ( Array ArrWord32 (SV.length indices) (withV indices)
                        , Array ArrFloat (2 * SV.length texcoords) (withV texcoords)
                        , posNorms
                        )
          where
            withV a f = SV.unsafeWith a (\p -> f $ castPtr p)
            tris = MD3.srTriangles sf
            indices = tris
            {-
            intToWord16 :: Int -> Word16
            intToWord16 = fromIntegral
            addIndex v i (a,b,c) = do
                SMV.write v i $ intToWord16 a
                SMV.write v (i+1) $ intToWord16 b
                SMV.write v (i+2) $ intToWord16 c
                return (i+3)
            indices = SV.create $ do
                v <- SMV.new $ 3 * V.length tris
                V.foldM_ (addIndex v) 0 tris
                return v
            -}
            texcoords = MD3.srTexCoords sf
            cvtPosNorm (p,n) = (f p, f n)
              where
                --f :: V.Vector Vec3 -> Array
                f sv = Array ArrFloat (3 * SV.length sv) $ withV sv
                --(p,n) = V.unzip pn
            posNorms = V.map cvtPosNorm $ MD3.srXyzNormal sf

        addSurface sf (il,tl,pl,nl,pnl) = (i:il,t:tl,p:pl,n:nl,pn:pnl)
          where
            (i,t,pn) = cvtSurface sf
            (p,n)    = V.head pn
        (il,tl,pl,nl,pnl)   = V.foldr addSurface ([],[],[],[],[]) surfaces
        surfaces            = MD3.mdSurfaces model
        numSurfaces         = V.length surfaces
        frames              = foldr addSurfaceFrames emptyFrame $ zip [0..] pnl
          where
            emptyFrame = V.replicate (V.length $ MD3.mdFrames model) []
            -- TODO: ????
            addSurfaceFrames (idx,pn) f = V.zipWith (\l (p,n) -> (2 * numSurfaces + idx,p):(3 * numSurfaces + idx,n):l) f pn

    {-
        buffer layout
          index arrays for surfaces         [index array of surface 0,          index array of surface 1,         ...]
          texture coord arrays for surfaces [texture coord array of surface 0,  texture coord array of surface 1, ...]
          position arrays for surfaces      [position array of surface 0,       position array of surface 1,      ...]
          normal arrays for surfaces        [normal array of surface 0,         normal array of surface 1,        ...]
        in short: [ surf1_idx..surfN_idx
                  , surf1_tex..surfN_tex
                  , surf1_pos..surfN_pos
                  , surf1_norm..surfN_norm
                  ]
    -}
    buffer <- compileBuffer $ concat [il,tl,pl,nl]

    objs <- forM (zip [0..] $ V.toList surfaces) $ \(idx,sf) -> do
        let countV = SV.length $ MD3.srTexCoords sf
            countI = SV.length (MD3.srTriangles sf)
            attrs = Map.fromList $
                [ ("diffuseUV",     Stream Attribute_V2F buffer (1 * numSurfaces + idx) 0 countV)
                , ("position",      Stream Attribute_V3F buffer (2 * numSurfaces + idx) 0 countV)
                , ("normal",        Stream Attribute_V3F buffer (3 * numSurfaces + idx) 0 countV)
                , ("color",         ConstV4F (V4 1 1 1 1))
                , ("lightmapUV",    ConstV2F (V2 0 0))
                ]
            index = IndexStream buffer idx 0 countI
            materialName s = case Map.lookup (SB8.unpack $ MD3.srName sf) skin of
              Nothing -> SB8.unpack $ MD3.shName s
              Just a  -> a
        objList <- concat <$> forM (V.toList $ MD3.srShaders sf) (\s -> do
          a <- addObject' r (materialName s) TriangleList (Just index) attrs ["worldMat"]
          b <- addObject r "LightMapOnly" TriangleList (Just index) attrs ["worldMat"]
          return [a,b])

        -- add collision geometry
        collisionObjs <- case V.toList $ MD3.mdFrames model of
          (MD3.Frame{..}:_) -> do
            sphereObj <- uploadMeshToGPU (sphere (V4 1 0 0 1) 4 frRadius) >>= addMeshToObjectArray r "CollisionShape" ["worldMat","origin"]
            boxObj <- uploadMeshToGPU (bbox (V4 0 0 1 1) frMins frMaxs) >>= addMeshToObjectArray r "CollisionShape" ["worldMat","origin"]
            when (frOrigin /= zero) $ putStrLn $ "frOrigin: " ++ show frOrigin
            return [sphereObj,boxObj]
          _ -> return []
        {-
          uploadMeshToGPU
          addMeshToObjectArray
          updateMesh :: GPUMesh -> [(String,MeshAttribute)] -> Maybe MeshPrimitive -> IO ()
        -}
        
        return $ objList ++ collisionObjs
    -- question: how will be the referred shaders loaded?
    --           general problem: should the gfx network contain all passes (every possible materials)?
    return $ LCMD3
        { lcmd3Object   = concat objs
        , lcmd3Buffer   = buffer
        , lcmd3Frames   = frames
        }

isClusterVisible :: BSPLevel -> Int -> Int -> Bool
isClusterVisible bl a b
    | a >= 0 = 0 /= (visSet .&. (shiftL 1 (b .&. 7)))
    | otherwise = True
  where
    Visibility nvecs szvecs vecs = blVisibility bl
    i = a * szvecs + (shiftR b 3)
    visSet = vecs V.! i

findLeafIdx bl camPos i
    | i >= 0 = if dist >= 0 then findLeafIdx bl camPos f else findLeafIdx bl camPos b
    | otherwise = (-i) - 1
  where 
    node    = blNodes bl V.! i
    (f,b)   = ndChildren node 
    plane   = blPlanes bl V.! ndPlaneNum node
    dist    = plNormal plane `dotprod` camPos - plDist plane

cullSurfaces :: BSPLevel -> Vec3 -> Frustum -> V.Vector [Object] -> IO ()
cullSurfaces bsp cam frust objs = case leafIdx < 0 || leafIdx >= V.length leaves of
    True    -> {-trace "findLeafIdx error" $ -}V.forM_ objs $ \objList -> forM_ objList $ \obj -> enableObject obj True
    False   -> {-trace ("findLeafIdx ok " ++ show leafIdx ++ " " ++ show camCluster) -}surfaceMask
  where
    leafIdx = findLeafIdx bsp cam 0
    leaves = blLeaves bsp
    camCluster = lfCluster $ leaves V.! leafIdx
    visibleLeafs = V.filter (\a -> (isClusterVisible bsp camCluster $ lfCluster a) && inFrustum a) leaves
    surfaceMask = do
        let leafSurfaces = blLeafSurfaces bsp
        V.forM_ objs $ \objList -> forM_ objList $ \obj -> enableObject obj False
        V.forM_ visibleLeafs $ \l ->
            V.forM_ (V.slice (lfFirstLeafSurface l) (lfNumLeafSurfaces l) leafSurfaces) $ \i ->
                forM_ (objs V.! i) $ \obj -> enableObject obj True
    inFrustum a = boxInFrustum (lfMaxs a) (lfMins a) frust

data Frustum
    = Frustum
    { frPlanes  :: [(Vec3, Float)]
    , ntl       :: Vec3
    , ntr       :: Vec3
    , nbl       :: Vec3
    , nbr       :: Vec3
    , ftl       :: Vec3
    , ftr       :: Vec3
    , fbl       :: Vec3
    , fbr       :: Vec3
    }

pointInFrustum p fr = foldl' (\b (n,d) -> b && d + n `dotprod` p >= 0) True $ frPlanes fr

sphereInFrustum p r fr = foldl' (\b (n,d) -> b && d + n `dotprod` p >= (-r)) True $ frPlanes fr

boxInFrustum pp pn fr = foldl' (\b (n,d) -> b && d + n `dotprod` (g pp pn n) >= 0) True $ frPlanes fr
  where
    g (Vec3 px py pz) (Vec3 nx ny nz) n = Vec3 (fx px nx) (fy py ny) (fz pz nz)
      where
        Vec3 x y z = n
        [fx,fy,fz] = map (\a -> if a > 0 then max else min) [x,y,z]

frustum :: Float -> Float -> Float -> Float -> Vec3 -> Vec3 -> Vec3 -> Frustum
frustum angle ratio nearD farD p l u = Frustum [ (pl ntr ntl ftl)
                                               , (pl nbl nbr fbr)
                                               , (pl ntl nbl fbl)
                                               , (pl nbr ntr fbr)
                                               , (pl ntl ntr nbr)
                                               , (pl ftr ftl fbl)
                                               ] ntl ntr nbl nbr ftl ftr fbl fbr
  where
    pl a b c = (n,d)
      where
        n = normalize $ (c - b) `crossprod` (a - b)
        d = -(n `dotprod` b)
    m a v = scalarMul a v
    ang2rad = pi / 180
    tang    = tan $ angle * ang2rad * 0.5
    nh  = nearD * tang
    nw  = nh * ratio
    fh  = farD * tang
    fw  = fh * ratio
    z   = normalize $ p - l
    x   = normalize $ u `crossprod` z
    y   = z `crossprod` x

    nc  = p - m nearD z
    fc  = p - m farD z

    ntl = nc + m nh y - m nw x
    ntr = nc + m nh y + m nw x
    nbl = nc - m nh y - m nw x
    nbr = nc - m nh y + m nw x

    ftl = fc + m fh y - m fw x
    ftr = fc + m fh y + m fw x
    fbl = fc - m fh y - m fw x
    fbr = fc - m fh y + m fw x

-- utility
sphere :: V4 Float -> Int -> Float -> Mesh
sphere color n radius = Mesh
    { mAttributes = Map.fromList [("position", A_V3F vertices), ("normal", A_V3F normals), ("color", A_V4F $ V.replicate (V.length vertices) color)]
    , mPrimitive = P_TrianglesI indices
    }
  where
    m = pi / fromIntegral n
    vertices = V.map (\(V3 x y z) -> V3 (radius * x) (radius * y) (radius * z)) normals
    normals = V.fromList [V3 (sin a * cos b) (cos a) (sin a * sin b) | i <- [0..n], j <- [0..2 * n - 1],
                          let a = fromIntegral i * m, let b = fromIntegral j * m]
    indices = V.fromList $ concat [[ix i j, ix i' j, ix i' j', ix i' j', ix i j', ix i j] | i <- [0..n - 1], j <- [0..2 * n - 1],
                                   let i' = i + 1, let j' = (j + 1) `mod` (2 * n)]
    ix i j = fromIntegral (i * 2 * n + j)

bbox :: V4 Float -> Vec3 -> Vec3 -> Mesh
bbox color (Vec3 minX minY minZ) (Vec3 maxX maxY maxZ) = Mesh
    { mAttributes = Map.fromList [("position", A_V3F vertices), ("color", A_V4F $ V.replicate (V.length vertices) color)]
    , mPrimitive = P_Triangles
    }
  where
    quads = [[6, 2, 3, 7], [5, 1, 0, 4], [7, 3, 1, 5], [4, 0, 2, 6], [3, 2, 0, 1], [6, 7, 5, 4]]
    indices = V.fromList $ concat [[a, b, c, c, d, a] | [d, c, b, a] <- quads]
    vertices = V.backpermute (V.generate 8 mkVertex) indices

    mkVertex n = V3 x y z
      where
        x = if testBit n 2 then maxX else minX
        y = if testBit n 1 then maxY else minY
        z = if testBit n 0 then maxZ else minZ
