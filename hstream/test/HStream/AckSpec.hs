module HStream.AckSpec (spec) where

import           Data.Map.Strict               as Map
import           HStream.Server.HStreamApi     (RecordId (..))
import           HStream.Server.Handler.Common (RecordIdRange (..),
                                                insertAckedRecordId,
                                                isSuccessor)
import           Test.Hspec

spec :: Spec
spec =  describe "HStream.AckSpec" $ do
  isSuccessorSpec
  insertAckSpec

isSuccessorSpec :: Spec
isSuccessorSpec =
  describe "isSuccessor" $ do
    it "in same batch match" $ do
      let r1 = RecordId 1 2
      let r2 = RecordId 1 1
      let batchNumMap = Map.singleton 1 100
      isSuccessor r1 r2 batchNumMap `shouldBe` True
    it "in same batch not match" $ do
      let r1 = RecordId 1 3
      let r2 = RecordId 1 1
      let batchNumMap = Map.singleton 1 100
      isSuccessor r1 r2 batchNumMap `shouldBe` False
    it "not same batch match" $ do
      let r1 = RecordId 2 0
      let r2 = RecordId 1 99
      let batchNumMap = Map.singleton 1 100
      isSuccessor r1 r2 batchNumMap `shouldBe` True
    it "not same batch not match" $ do
      let r1 = RecordId 2 1
      let r2 = RecordId 1 99
      let batchNumMap = Map.singleton 1 100
      isSuccessor r1 r2 batchNumMap `shouldBe` False
    it "minBound as r1" $ do
      let r1 = minBound
      let r2 = RecordId 1 99
      let batchNumMap = Map.singleton 1 100
      isSuccessor r1 r2 batchNumMap `shouldBe` False
    it "minBound as r2" $ do
      let r1 = RecordId 1 2
      let r2 = minBound
      let batchNumMap = Map.singleton 1 100
      isSuccessor r1 r2 batchNumMap `shouldBe` False
    it "maxBound as r1" $ do
      let r1 = maxBound
      let r2 = RecordId 1 99
      let batchNumMap = Map.singleton 1 100
      isSuccessor r1 r2 batchNumMap `shouldBe` False
    it "maxBound as r2" $ do
      let r1 = RecordId 1 2
      let r2 = maxBound
      let batchNumMap = Map.singleton 1 100
      isSuccessor r1 r2 batchNumMap `shouldBe` False

insertAckSpec :: Spec
insertAckSpec =
  describe "insertAckedRecordId" $ do
    it "inset to empty" $ do
      let oldRanges = Map.empty
      let r = RecordId 1 1
      let batchNumMap = Map.singleton 1 3
      insertAckedRecordId r oldRanges batchNumMap `shouldBe` Map.singleton r (RecordIdRange r r)
    it "no merge" $ do
      let range1L = RecordId 1 0
      let range1R = RecordId 2 0

      let range2L = RecordId 3 1
      let range2R = RecordId 3 2

      let oldRanges = Map.fromList [(range1L, RecordIdRange range1L range1R), (range2L, RecordIdRange range2L range2R)]
      let newR = RecordId 2 2
      let newRanges = Map.insert newR (RecordIdRange newR newR) oldRanges
      let batchNumMap = Map.fromList [(1, 5), (2, 5), (3, 5)]
      insertAckedRecordId newR oldRanges batchNumMap `shouldBe` newRanges
    it "no merge 2" $ do
      let range1L = RecordId 1 0
      let range1R = RecordId 2 0

      let range2L = RecordId 3 1
      let range2R = RecordId 3 2

      let oldRanges = Map.fromList [(range1L, RecordIdRange range1L range1R), (range2L, RecordIdRange range2L range2R)]
      let newR = RecordId 4 2
      let newRanges = Map.fromList [(range1L, RecordIdRange range1L range1R), (range2L, RecordIdRange range2L range2R), (newR, RecordIdRange newR newR)]
      let batchNumMap = Map.fromList [(1, 5), (2, 5), (3, 5), (4, 5)]
      insertAckedRecordId newR oldRanges batchNumMap `shouldBe` newRanges
    it "no merge 3" $ do
      let range1L = RecordId 1 2
      let range1R = RecordId 2 0

      let range2L = RecordId 3 1
      let range2R = RecordId 3 2

      let oldRanges = Map.fromList [(range1L, RecordIdRange range1L range1R), (range2L, RecordIdRange range2L range2R)]
      let newR = RecordId 1 0
      let newRanges = Map.fromList [(newR, RecordIdRange newR newR), (range1L, RecordIdRange range1L range1R), (range2L, RecordIdRange range2L range2R)]
      let batchNumMap = Map.fromList [(1, 5), (2, 5), (3, 5), (4, 5)]
      insertAckedRecordId newR oldRanges batchNumMap `shouldBe` newRanges
    it "merge to left" $ do
      let range1L = RecordId 1 0
      let range1R = RecordId 2 0

      let range2L = RecordId 3 1
      let range2R = RecordId 3 2

      let oldRanges = Map.fromList [(range1L, RecordIdRange range1L range1R), (range2L, RecordIdRange range2L range2R)]
      let newR = RecordId 2 1
      let newRanges = Map.fromList [(range1L, RecordIdRange range1L newR), (range2L, RecordIdRange range2L range2R)]
      let batchNumMap = Map.fromList [(1, 5), (2, 5), (3, 5)]
      insertAckedRecordId newR oldRanges batchNumMap `shouldBe` newRanges
    it "merge to left 1" $ do
      let range1L = RecordId 1 0
      let range1R = RecordId 2 0

      let oldRanges = Map.fromList [(range1L, RecordIdRange range1L range1R)]
      let newR = RecordId 2 1
      let newRanges = Map.fromList [(range1L, RecordIdRange range1L newR)]
      let batchNumMap = Map.fromList [(1, 5), (2, 5), (3, 5)]
      insertAckedRecordId newR oldRanges batchNumMap `shouldBe` newRanges
    it "merge to right" $ do
      let range1L = RecordId 1 0
      let range1R = RecordId 2 0

      let range2L = RecordId 3 1
      let range2R = RecordId 3 2

      let oldRanges = Map.fromList [(range1L, RecordIdRange range1L range1R), (range2L, RecordIdRange range2L range2R)]
      let newR = RecordId 3 0
      let newRanges = Map.fromList [(range1L, RecordIdRange range1L range1R), (newR, RecordIdRange newR range2R)]
      let batchNumMap = Map.fromList [(1, 5), (2, 5), (3, 5)]
      insertAckedRecordId newR oldRanges batchNumMap `shouldBe` newRanges
    it "merge to right 2" $ do
      let range1L = RecordId 1 0
      let range1R = RecordId 2 0

      let range2L = RecordId 3 1
      let range2R = RecordId 3 2

      let oldRanges = Map.fromList [(range1L, RecordIdRange range1L range1R), (range2L, RecordIdRange range2L range2R)]
      let newR = RecordId 3 3
      let newRanges = Map.fromList [(range1L, RecordIdRange range1L range1R), (range2L, RecordIdRange range2L newR)]
      let batchNumMap = Map.fromList [(1, 5), (2, 5), (3, 5)]
      insertAckedRecordId newR oldRanges batchNumMap `shouldBe` newRanges
    it "merge to right 3" $ do
      let range2L = RecordId 3 1
      let range2R = RecordId 3 2

      let oldRanges = Map.fromList [(range2L, RecordIdRange range2L range2R)]
      let newR = RecordId 3 0
      let newRanges = Map.fromList [(newR, RecordIdRange newR range2R)]
      let batchNumMap = Map.fromList [(1, 5), (2, 5), (3, 5)]
      insertAckedRecordId newR oldRanges batchNumMap `shouldBe` newRanges
    it "merge to left and right" $ do
      let range1L = RecordId 1 0
      let range1R = RecordId 2 4

      let range2L = RecordId 3 1
      let range2R = RecordId 3 2

      let oldRanges = Map.fromList [(range1L, RecordIdRange range1L range1R), (range2L, RecordIdRange range2L range2R)]
      let newR = RecordId 3 0
      let newRanges = Map.fromList [(range1L, RecordIdRange range1L range2R)]
      let batchNumMap = Map.fromList [(1, 5), (2, 5), (3, 5)]
      insertAckedRecordId newR oldRanges batchNumMap `shouldBe` newRanges

