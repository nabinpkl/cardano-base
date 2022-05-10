{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoStarIsType #-}
{-# LANGUAGE MultiParamTypeClasses #-}

-- | Mock key evolving signatures.
module Cardano.Crypto.KES.Simple
  ( SimpleKES
  , SigKES (..)
  , SignKeyKES (SignKeySimpleKES, ThunkySignKeySimpleKES)
  )
where

import           Data.List (unfoldr)
import           Data.Proxy (Proxy (..))
import           Data.Typeable (Typeable)
import qualified Data.ByteString as BS
import           Data.Vector ((!?), Vector)
import qualified Data.Vector as Vec
import           GHC.Generics (Generic)
import           GHC.TypeNats (Nat, KnownNat, natVal, type (*))
import           NoThunks.Class (NoThunks)

import           Cardano.Prelude (forceElemsToWHNF)
import           Cardano.Binary (FromCBOR (..), ToCBOR (..))

import           Cardano.Crypto.DSIGN
import qualified Cardano.Crypto.DSIGN as DSIGN
import           Cardano.Crypto.KES.Class
import           Cardano.Crypto.Seed
import           Cardano.Crypto.Util
import           Cardano.Crypto.MonadSodium (MonadSodium (..))


data SimpleKES d (t :: Nat)

-- | 'VerKeySimpleKES' uses a boxed 'Vector', which is lazy in its elements.
-- We don't want laziness and the potential space leak, so we use this pattern
-- synonym to force the elements of the vector to WHNF upon construction.
--
-- The alternative is to use an unboxed vector, but that would require an
-- unreasonable 'Unbox' constraint.
pattern VerKeySimpleKES :: Vector (VerKeyDSIGN d) -> VerKeyKES (SimpleKES d t)
pattern VerKeySimpleKES v <- ThunkyVerKeySimpleKES v
  where
    VerKeySimpleKES v = ThunkyVerKeySimpleKES (forceElemsToWHNF v)

{-# COMPLETE VerKeySimpleKES #-}

-- | See 'VerKeySimpleKES'.
pattern SignKeySimpleKES :: Vector (SignKeyDSIGN d) -> SignKeyKES (SimpleKES d t)
pattern SignKeySimpleKES v <- ThunkySignKeySimpleKES v
  where
    SignKeySimpleKES v = ThunkySignKeySimpleKES (forceElemsToWHNF v)

{-# COMPLETE SignKeySimpleKES #-}

instance ( DSIGNAlgorithm d
         , Typeable d
         , KnownNat t
         , KnownNat (SeedSizeDSIGN d * t)
         , KnownNat (SizeVerKeyDSIGN d * t)
         , KnownNat (SizeSignKeyDSIGN d * t)
         )
         => KESAlgorithm (SimpleKES d t) where

    type SeedSizeKES (SimpleKES d t) = SeedSizeDSIGN d * t

    --
    -- Key and signature types
    --

    newtype VerKeyKES (SimpleKES d t) =
              ThunkyVerKeySimpleKES (Vector (VerKeyDSIGN d))
        deriving Generic

    newtype SignKeyKES (SimpleKES d t) =
              ThunkySignKeySimpleKES (Vector (SignKeyDSIGN d))
        deriving Generic

    newtype SigKES (SimpleKES d t) =
              SigSimpleKES (SigDSIGN d)
        deriving Generic


    --
    -- Metadata and basic key operations
    --

    algorithmNameKES proxy = "simple_" ++ show (totalPeriodsKES proxy)

    totalPeriodsKES  _ = fromIntegral (natVal (Proxy @ t))

    --
    -- Core algorithm operations
    --

    type ContextKES (SimpleKES d t) = DSIGN.ContextDSIGN d
    type Signable   (SimpleKES d t) = DSIGN.Signable     d

    verifyKES ctxt (VerKeySimpleKES vks) j a (SigSimpleKES sig) =
        case vks !? fromIntegral j of
          Nothing -> Left "KES verification failed: out of range"
          Just vk -> verifyDSIGN ctxt vk a sig

    --
    -- Key generation
    --

    seedSizeKES _ =
        let seedSize = seedSizeDSIGN (Proxy :: Proxy d)
            duration = fromIntegral (natVal (Proxy @t))
         in duration * seedSize

    --
    -- raw serialise/deserialise
    --

    type SizeVerKeyKES  (SimpleKES d t) = SizeVerKeyDSIGN d * t
    type SizeSignKeyKES (SimpleKES d t) = SizeSignKeyDSIGN d * t
    type SizeSigKES     (SimpleKES d t) = SizeSigDSIGN d

    rawSerialiseVerKeyKES (VerKeySimpleKES vks) =
        BS.concat [ rawSerialiseVerKeyDSIGN vk | vk <- Vec.toList vks ]

    rawSerialiseSigKES (SigSimpleKES sig) =
        rawSerialiseSigDSIGN sig

    rawDeserialiseVerKeyKES bs
      | let duration = fromIntegral (natVal (Proxy :: Proxy t))
            sizeKey  = fromIntegral (sizeVerKeyDSIGN (Proxy :: Proxy d))
      , vkbs     <- splitsAt (replicate duration sizeKey) bs
      , length vkbs == duration
      , Just vks <- mapM rawDeserialiseVerKeyDSIGN vkbs
      = Just $! VerKeySimpleKES (Vec.fromList vks)

      | otherwise
      = Nothing

    rawDeserialiseSigKES = fmap SigSimpleKES . rawDeserialiseSigDSIGN



instance ( KESAlgorithm (SimpleKES d t)
         , DSIGNAlgorithm d
         , Typeable d
         , KnownNat t
         , KnownNat (SeedSizeDSIGN d * t)
         , KnownNat (SizeVerKeyDSIGN d * t)
         , KnownNat (SizeSignKeyDSIGN d * t)
         , MonadSodium m
         ) =>
         KESSignAlgorithm m (SimpleKES d t) where

    deriveVerKeyKES (SignKeySimpleKES sks) =
        return $! VerKeySimpleKES (Vec.map deriveVerKeyDSIGN sks)


    signKES ctxt j a (SignKeySimpleKES sks) =
        case sks !? fromIntegral j of
          Nothing -> error ("SimpleKES.signKES: period out of range " ++ show j)
          Just sk -> return $ SigSimpleKES (signDSIGN ctxt a sk)

    updateKES _ sk t
      | t+1 < fromIntegral (natVal (Proxy @ t)) = return $ Just sk
      | otherwise                               = return Nothing


    --
    -- Key generation
    --

    genKeyKES mlsb = do
        seed <- mkSeedFromBytes <$> mlsbToByteString mlsb
        let seedSize = seedSizeDSIGN (Proxy :: Proxy d)
            duration = fromIntegral (natVal (Proxy @ t))
            seeds    = take duration
                     . map mkSeedFromBytes
                     $ unfoldr (getBytesFromSeed seedSize) seed
            sks      = map genKeyDSIGN seeds
        return $! SignKeySimpleKES (Vec.fromList sks)


    --
    -- raw serialise/deserialise
    --

    rawSerialiseSignKeyKES (SignKeySimpleKES sksVec) mlsb offset = do
      buf <- mlsbFromByteString @m @(SizeSignKeyKES (SimpleKES d t)) bs
      mlsbMemcpy mlsb offset buf 0 (sizeSignKeyKES (Proxy @(SimpleKES d t)))
      mlsbFinalize buf
      where
        sks = Vec.toList sksVec
        bs = BS.concat (map rawSerialiseSignKeyDSIGN sks)


    rawDeserialiseSignKeyKES mlsb offset = do
      buf <- mlsbNew @m @(SizeSignKeyDSIGN d)
      sks <- mapM
              (\o -> do
                      mlsbMemcpy buf 0 mlsb o sizeKey
                      bs <- mlsbToByteString buf
                      return $ rawDeserialiseSignKeyDSIGN bs
              )
              offsets
      mlsbFinalize buf
      return $ SignKeySimpleKES . Vec.fromList <$> sequence sks
      where
        duration = fromIntegral (natVal (Proxy :: Proxy t))
        sizeKey  = fromIntegral (sizeSignKeyDSIGN (Proxy :: Proxy d))
        offsets  = [ offset + x * sizeKey | x <- [0..duration-1] ]

deriving instance DSIGNAlgorithm d => Show (VerKeyKES (SimpleKES d t))
deriving instance DSIGNAlgorithm d => Show (SignKeyKES (SimpleKES d t))
deriving instance DSIGNAlgorithm d => Show (SigKES (SimpleKES d t))

deriving instance DSIGNAlgorithm d => Eq   (VerKeyKES (SimpleKES d t))
deriving instance DSIGNAlgorithm d => Eq   (SigKES (SimpleKES d t))

instance DSIGNAlgorithm d => NoThunks (SigKES     (SimpleKES d t))
instance DSIGNAlgorithm d => NoThunks (SignKeyKES (SimpleKES d t))
instance DSIGNAlgorithm d => NoThunks (VerKeyKES  (SimpleKES d t))

instance ( DSIGNAlgorithm d
         , Typeable d
         , KnownNat t
         , KnownNat (SeedSizeDSIGN d * t)
         , KnownNat (SizeVerKeyDSIGN d * t)
         , KnownNat (SizeSignKeyDSIGN d * t)
         )
      => ToCBOR (VerKeyKES (SimpleKES d t)) where
  toCBOR = encodeVerKeyKES
  encodedSizeExpr _size = encodedVerKeyKESSizeExpr

instance ( DSIGNAlgorithm d
         , Typeable d
         , KnownNat t
         , KnownNat (SeedSizeDSIGN d * t)
         , KnownNat (SizeVerKeyDSIGN d * t)
         , KnownNat (SizeSignKeyDSIGN d * t)
         )
      => FromCBOR (VerKeyKES (SimpleKES d t)) where
  fromCBOR = decodeVerKeyKES

instance ( DSIGNAlgorithm d
         , Typeable d
         , KnownNat t
         , KnownNat (SeedSizeDSIGN d * t)
         , KnownNat (SizeVerKeyDSIGN d * t)
         , KnownNat (SizeSignKeyDSIGN d * t)
         )
      => ToCBOR (SigKES (SimpleKES d t)) where
  toCBOR = encodeSigKES
  encodedSizeExpr _size = encodedSigKESSizeExpr

instance (DSIGNAlgorithm d
         , Typeable d
         , KnownNat t
         , KnownNat (SeedSizeDSIGN d * t)
         , KnownNat (SizeVerKeyDSIGN d * t)
         , KnownNat (SizeSignKeyDSIGN d * t)
         )
      => FromCBOR (SigKES (SimpleKES d t)) where
  fromCBOR = decodeSigKES

