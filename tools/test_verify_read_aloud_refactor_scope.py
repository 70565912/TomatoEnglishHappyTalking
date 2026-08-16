#!/usr/bin/env python3

from __future__ import annotations

import hashlib
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from verify_read_aloud_behavior_baseline import sentence_boundaries
from verify_read_aloud_refactor_scope import (
    boundary_is_inside_matched_parenthetical,
    verify_scope,
)


def oracle(sentences: list[str]) -> dict:
    source, boundaries = sentence_boundaries(sentences)
    return {
        "schemaVersion": "read_aloud_solver_oracle_v1",
        "books": [
            {
                "book": "Alice",
                "chapters": [
                    {
                        "episode": "E02",
                        "canonicalSourceSha256": hashlib.sha256(
                            source.encode("utf-8")
                        ).hexdigest(),
                        "boundaryCanonicalOffsets": boundaries,
                        "sentences": sentences,
                    }
                ],
            }
        ],
    }


def report(sentences: list[str]) -> dict:
    return {"chapters": [{"episode": "E02", "v3LocalSentences": sentences}]}


class RefactorScopeVerifierTest(unittest.TestCase):
    def test_exact_match_passes(self) -> None:
        expected = ["(One,", "two);", "outside."]
        self.assertTrue(verify_scope(oracle(expected), {"alice": report(expected)})["passed"])

    def test_matched_parenthetical_change_is_reported_and_fails(self) -> None:
        expected = ["(One,", "two);", "outside."]
        changed = ["(One, two);", "outside."]
        result = verify_scope(oracle(expected), {"alice": report(changed)})
        self.assertFalse(result["passed"])
        self.assertEqual(
            result["books"][0]["parentheticalOnlyDifferentChapterCount"],
            1,
        )

    def test_parenthetical_attachment_edges_are_in_scope(self) -> None:
        source = "lead(aside);tail"
        self.assertTrue(boundary_is_inside_matched_parenthetical(source, 4))
        self.assertTrue(boundary_is_inside_matched_parenthetical(source, 11))
        self.assertTrue(boundary_is_inside_matched_parenthetical(source, 12))

    def test_following_word_boundary_is_out_of_scope(self) -> None:
        source = "lead(aside)couldnotmakeout"
        self.assertFalse(boundary_is_inside_matched_parenthetical(source, 22))

    def test_outside_change_fails(self) -> None:
        expected = ["(One,", "two);", "outside,", "tail."]
        changed = ["(One,", "two);", "outside, tail."]
        self.assertFalse(verify_scope(oracle(expected), {"alice": report(changed)})["passed"])

    def test_unmatched_open_does_not_authorize_drift(self) -> None:
        source = "outside(unmatchedtail"
        self.assertFalse(boundary_is_inside_matched_parenthetical(source, 15))


if __name__ == "__main__":
    unittest.main()
