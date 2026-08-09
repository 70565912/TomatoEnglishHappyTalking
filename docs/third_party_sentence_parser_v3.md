# Sentence parser V3 third-party notice

The app uses source code from **UDPipe 1.4.0**, copyright Institute of Formal
and Applied Linguistics, Faculty of Mathematics and Physics, Charles
University. UDPipe is distributed under the Mozilla Public License 2.0. The
vendored license and source are retained under
`app/packages/udpipe_parser_v3/third_party/udpipe/`.

The bundled English parser model is trained by this project from **Universal
Dependencies English Web Treebank r2.18**. UD English EWT is distributed under
Creative Commons Attribution-ShareAlike 4.0. The fixed training files,
upstream README and full license are retained under
`tools/sentence_split_v3/training/ud_english_ewt_r2_18/`.

The accepted model is `english-ewt-r2.18-udpipe-v1.4.0.model`, SHA-256
`b71fb73473bedbca575bfc927fceb0f6dd53f74493bb9c58a9e77bd28d24a71f`.
On the untouched EWT r2.18 test split its raw-text evaluation is word F1
98.96%, sentence F1 85.93%, UPOS 93.99%, UAS 81.16% and LAS 77.81%.
Task-level V3.3 evaluation remains the acceptance authority: approved-path
coverage is 243/243 and the frozen 60-case holdout is 60/60.

No official UDPipe pretrained linguistic model is bundled or used. This
notice documents provenance and redistribution terms; it is not legal advice.

For development comparison only, an official English-EWT 2.5 model may be
downloaded into ignored `build/udpipe-reference/`. It is never copied into
Flutter assets, installers, APKs, or published archives. spaCy and Stanza
models used by the comparison script are likewise build-only evaluation
dependencies and are not App dependencies.

The three parsers are not assumed to form a majority-vote oracle. Direct
comparison has found literary and generic long sentences where the official
UDPipe model assigns the wrong predicate root, subject, or clause attachment
while spaCy and Stanza preserve a more plausible boundary. Conversely, the
reference parsers also disagree on quotation structures. These failures are
recorded as task-level parser-health evidence; they must not be converted into
word exceptions. Stanza's Python/PyTorch pipeline and spaCy's Python runtime
are not drop-in Windows/Android native dependencies, so they remain reference
implementations unless a separately verified mobile inference design is
approved.

The read-aloud solver consumes only generic Universal Dependencies relations.
Book names, character names, isolated bad-example words and semantic word lists
are prohibited in production rules. Regression examples may contain specific
phrases, but they cannot change the generic decision policy.

Project-model training writes a same-directory `.training` artifact
and replaces the packaged model only after the trainer exits successfully.
The App also verifies a pinned model SHA-256 at runtime, so a partial or
silently replaced model cannot enter the V3 cache identity.
