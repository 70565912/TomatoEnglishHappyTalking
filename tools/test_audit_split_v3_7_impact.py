import importlib.util
from pathlib import Path
import unittest


_SPEC = importlib.util.spec_from_file_location(
    "audit_split_v3_7_impact",
    Path(__file__).with_name("audit_split_v3_7_impact.py"),
)
if _SPEC is None or _SPEC.loader is None:
    raise RuntimeError("Cannot load audit_split_v3_7_impact.py")
audit = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(audit)


def _words(count: int) -> list[str]:
    return [f"word{index}" for index in range(1, count + 1)]


def _chapter(source: str, after_word: int) -> dict:
    return {
        "episode": "E01",
        "originals": [
            {
                "original": source,
                "boundaryCandidates": [
                    {
                        "afterWord": after_word,
                        "kind": "dependencyClause",
                        "hardBlocked": False,
                        "reasons": ["dependency_clause_with_outer_container_arcs"],
                        "softWarnings": [
                            "surface_nominal_coordinator_separation"
                        ],
                    }
                ],
            }
        ],
    }


class AtomicImpactAuditTest(unittest.TestCase):
    def test_accepts_only_one_for_one_incomplete_repair(self) -> None:
        self.assertEqual(
            audit.direct_incomplete_repair_offsets(
                {10},
                {10},
                {12},
                20,
            ),
            {10, 12},
        )
        self.assertEqual(
            audit.direct_incomplete_repair_offsets(
                {10},
                {10, 15},
                {12},
                20,
            ),
            set(),
        )

    def test_accepts_a_pure_comfort_insertion(self) -> None:
        words = _words(30)
        source = " ".join(words)
        old = [" ".join(words[:23]), " ".join(words[23:])]
        new = [" ".join(words[:16]), " ".join(words[16:23]), old[1]]
        offset = len(audit.canonical(" ".join(words[:16])))
        self.assertEqual(
            audit.comfort_split_offsets(_chapter(source, 16), source, old, new),
            {offset},
        )

    def test_rejects_comfort_insertion_that_moves_an_old_edge(self) -> None:
        words = _words(30)
        source = " ".join(words)
        old = [" ".join(words[:23]), " ".join(words[23:])]
        new = [
            " ".join(words[:16]),
            " ".join(words[16:24]),
            " ".join(words[24:]),
        ]
        self.assertEqual(
            audit.comfort_split_offsets(_chapter(source, 16), source, old, new),
            set(),
        )


if __name__ == "__main__":
    unittest.main()
