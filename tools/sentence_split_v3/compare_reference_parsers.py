"""Development-only comparison of UDPipe, spaCy, and Stanza dependencies.

This tool never participates in production sentence splitting. It produces an
auditable relation report so parser disagreements are reviewed structurally
instead of being patched with book names or lexical cut exceptions.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import tempfile
from pathlib import Path

import spacy
import stanza


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--udpipe-probe", type=Path, required=True)
    parser.add_argument("--udpipe-model", type=Path, required=True)
    parser.add_argument("--stanza-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args()


def token_json(
    *, index: int, text: str, upos: str, head: int, relation: str
) -> dict[str, object]:
    return {
        "id": index,
        "text": text,
        "upos": upos,
        "head": head,
        "relation": relation,
    }


def run_udpipe(
    probe: Path, model: Path, lines: list[str]
) -> list[list[dict[str, object]]]:
    with tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", suffix=".txt", delete=False
    ) as handle:
        handle.write("\n".join(lines))
        temporary_path = Path(handle.name)
    try:
        completed = subprocess.run(
            [str(probe), str(model), str(temporary_path), "--presegmented"],
            check=True,
            capture_output=True,
            text=True,
            encoding="utf-8",
        )
        payload = json.loads(completed.stdout)
        sentences = payload["sentences"]
        if len(sentences) != len(lines):
            raise RuntimeError(
                f"UDPipe returned {len(sentences)} sentences for {len(lines)} lines"
            )
        return [
            [
                token_json(
                    index=token["id"],
                    text=token["sourceText"],
                    upos=token["upos"],
                    head=token["head"],
                    relation=token["deprel"],
                )
                for token in sentence["tokens"]
            ]
            for sentence in sentences
        ]
    finally:
        temporary_path.unlink(missing_ok=True)


def main() -> None:
    args = parse_args()
    lines = [
        line.strip()
        for line in args.input.read_text(encoding="utf-8-sig").splitlines()
        if line.strip()
    ]
    if not lines:
        raise RuntimeError("reference parser input is empty")

    spacy_parser = spacy.load("en_core_web_sm")
    stanza_parser = stanza.Pipeline(
        "en",
        model_dir=str(args.stanza_dir),
        processors="tokenize,mwt,pos,lemma,depparse",
        tokenize_no_ssplit=True,
        download_method=None,
        use_gpu=False,
        verbose=False,
    )
    udpipe_results = run_udpipe(args.udpipe_probe, args.udpipe_model, lines)

    cases: list[dict[str, object]] = []
    for case_index, source in enumerate(lines):
        spacy_doc = spacy_parser(source)
        stanza_doc = stanza_parser(source)
        stanza_words = [
            word for sentence in stanza_doc.sentences for word in sentence.words
        ]
        cases.append(
            {
                "caseIndex": case_index,
                "source": source,
                "udpipe": udpipe_results[case_index],
                "spacy": [
                    token_json(
                        index=token.i + 1,
                        text=token.text,
                        upos=token.pos_,
                        head=0 if token.head is token else token.head.i + 1,
                        relation=token.dep_.lower(),
                    )
                    for token in spacy_doc
                ],
                "stanza": [
                    token_json(
                        index=word.id,
                        text=word.text,
                        upos=word.upos,
                        head=word.head,
                        relation=word.deprel,
                    )
                    for word in stanza_words
                ],
            }
        )

    payload = {
        "schemaVersion": "sentence_parser_reference_v3_1",
        "productionParser": "udpipe-1.4.0",
        "referenceParsers": {
            "spacy": spacy.__version__,
            "stanza": stanza.__version__,
        },
        "caseCount": len(cases),
        "cases": cases,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"wrote {len(cases)} cases to {args.output}")


if __name__ == "__main__":
    main()
