# English read-aloud V3 parser model

The production parser is UDPipe 1.4.0 built from the fixed upstream tag
`v1.4.0` (`a0e72fcb1ba0d36998dc671db4350bbd159861b5`). The project model is
trained from UD English EWT `r2.18`
(`6e064999a75b9c941c515ce1be98352e6f9831e0`). It does not reuse the
non-commercial pretrained linguistic models published by UDPipe.

Source archive SHA-256 values used for this checkout:

- UDPipe v1.4.0: `E405EC6C27FF1C7FEFDD511DF516A361EC5A034B28F661CDE71DA7332A6F3B27`
- UD English EWT r2.18: `DD1B0E77BDBED3D1B2C66EBDC989E01E6456713384504D9E3C12BF2ED4298081`

The treebank files and license are in `training/ud_english_ewt_r2_18/`.
UDPipe source and its MPL-2.0 license are in
`app/packages/udpipe_parser_v3/third_party/udpipe/`.

Accepted packaged model:

- file: `app/assets/models/english-ewt-r2.18-udpipe-v1.4.0.model`
- SHA-256: `b71fb73473bedbca575bfc927fceb0f6dd53f74493bb9c58a9e77bd28d24a71f`
- untouched EWT r2.18 test: word F1 98.96%, sentence F1 85.93%, UPOS 93.99%,
  UAS 81.16%, LAS 77.81%
- task gates: 243/243 approved-path coverage, 10/10 generic difficult-input
  coverage, 60/60 frozen EWT holdout

## Reproducible Windows build and training

Build the trainer once, then run the checked-in bounded training command:

```powershell
cmake -S tools/sentence_split_v3 -B build/udpipe-v3-trainer -A x64
cmake --build build/udpipe-v3-trainer --config Release --target udpipe_v3_train
D:\PowerShell\7\pwsh.exe -NoProfile -File tools\sentence_split_v3\train_model.ps1
```

`train_model.ps1` fixes tokenizer/tagger/parser iteration bounds and retains
heldout-driven early stopping. It contains no book names, character names,
semantic cut-word lists or bad-example exceptions. Any future hyperparameter
change requires a new model SHA-256 and regression report; it must not be
hidden behind the existing V3 cache identity.

The script trains to a same-directory `.training` file and replaces the model
only after a successful exit. A cancelled or failed future run therefore
cannot overwrite a previously accepted model with a partial artifact. Model
size, independent evaluation, and SHA verification remain mandatory before
packaging.

After training, evaluate raw-text tokenization, tagging and dependency parsing
on the untouched EWT test split:

```powershell
D:\PowerShell\7\pwsh.exe -NoProfile -File tools\sentence_split_v3\evaluate_model.ps1 `
  -ModelPath app\assets\models\english-ewt-r2.18-udpipe-v1.4.0.model
```

The published UDPipe 1 English-EWT 2.5 raw-text reference is Words 98.9%,
Sentences 77.4%, UPOS 93.3%, UAS 80.2% and LAS 77.0%. A project model is not
accepted merely because training completes: report its independent-test result
and compare sentence-splitting gates as well as aggregate parser accuracy.

## Read-only Willows corpus audit

After a model passes the independent parser and generic candidate gates, run
the canonical Dart/native pipeline across E01-E62 from `app/`:

```powershell
D:\DevTools\flutter\bin\dart.bat run tool\split_willows_sentences.dart `
  --work F:\柳林风声\work `
  --output F:\TomatoEnglishHappyTalking\output\sentence-split-v3\willows-corpus
```

Use `--episode E01` for a bounded diagnostic and `--model <path>` to compare a
development model. Reports include parser tokens and dependency trees as well
as paths and sentence metrics. The command writes only its `--output`
directory; it never mutates the source corpus, App database, TTS, subtitles,
videos, picture mappings, or NAS files.
