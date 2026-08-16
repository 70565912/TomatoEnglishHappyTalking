#!/usr/bin/env python3

from __future__ import annotations

import unittest
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from verify_read_aloud_behavior_baseline import (
    boundary_is_inside_parenthetical,
    sentence_boundaries,
    verify,
)


def fixture(sentences: list[str]) -> dict:
    source, boundaries = sentence_boundaries(sentences)
    import hashlib

    return {
        "schemaVersion": "read_aloud_published_behavior_v1",
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
    return {
        "chapters": [
            {"episode": "E02", "v3LocalSentences": sentences},
        ]
    }


class PublishedBehaviorVerifierTest(unittest.TestCase):
    def test_exact_match_passes(self) -> None:
        expected = ["(One,", "two);", "outside."]
        result = verify(fixture(expected), {"alice": report(expected)})
        self.assertTrue(result["passed"])

    def test_parenthetical_drift_still_fails(self) -> None:
        expected = ["(One,", "two);", "outside."]
        changed = ["(One, two);", "outside."]
        result = verify(fixture(expected), {"alice": report(changed)})
        self.assertFalse(result["passed"])
        difference = result["books"][0]["differences"][0]
        self.assertEqual(difference["outsideParentheticalBoundaryOffsets"], [])

    def test_outside_drift_is_reported_and_fails(self) -> None:
        expected = ["(One,", "two);", "outside,", "tail."]
        changed = ["(One,", "two); outside,", "tail."]
        result = verify(fixture(expected), {"alice": report(changed)})
        self.assertFalse(result["passed"])
        difference = result["books"][0]["differences"][0]
        self.assertTrue(difference["outsideParentheticalBoundaryOffsets"])

    def test_parenthetical_classifier_handles_nested_spans(self) -> None:
        source = "a(b(c)d)e"
        self.assertTrue(boundary_is_inside_parenthetical(source, 4))
        self.assertTrue(boundary_is_inside_parenthetical(source, 7))
        self.assertFalse(boundary_is_inside_parenthetical(source, 8))


if __name__ == "__main__":
    unittest.main()
