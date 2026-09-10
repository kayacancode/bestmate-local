import unittest
from backends import grounding_issues

class GroundingTests(unittest.TestCase):
    def test_transition_is_not_a_hallucination(self):
        self.assertEqual(grounding_issues([{'faithfulness':'faithful'},{'faithfulness':'NA','explanation':'Not a factual claim.'}]),[])
    def test_partial_unfaithful_unknown_and_empty_still_fail(self):
        for label in ['partial','unfaithful','unexpected',None]:
            self.assertTrue(grounding_issues([{'faithfulness':label}]))
        self.assertTrue(grounding_issues([]))
        self.assertTrue(grounding_issues([{'faithfulness':'NA'}]))
