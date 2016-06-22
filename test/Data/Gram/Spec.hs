module Data.Gram.Spec where

import Data.DList as DList
import Data.Gram
import Data.Gram.Arbitrary ()
import Data.String
import Prologue
import Test.Hspec
import Test.Hspec.QuickCheck
import Test.QuickCheck

spec :: Spec
spec = parallel $ do
  describe "pqGrams" $
    it "exists" pending

  describe "featureVector" $ do
    prop "produces a vector of the specified dimension" $ forAll (arbitrary `suchThat` ((> 0) . snd)) $
      \ (grams, d) -> length (featureVector (fromList (grams :: [Gram String])) d) `shouldBe` d
