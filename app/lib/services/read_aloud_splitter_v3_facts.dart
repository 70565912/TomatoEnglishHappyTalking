part of 'read_aloud_splitter_v3.dart';

/// Stable Universal Dependencies facts used by the V3 splitter.
///
/// Keeping declarative grammar facts outside the path solver makes it harder
/// to hide scoring or book-specific exceptions among structural relations.
const _protectedRelations = <String>{
  'det',
  'case',
  'aux',
  'cop',
  'mark',
  'cc',
  'compound',
  'compound:prt',
  'fixed',
  'flat',
  'amod',
  'nsubj',
  'csubj',
  'obj',
  'iobj',
  'nummod',
  'nmod:poss',
};

const _clauseRelations = <String>{
  'conj',
  'advcl',
  'ccomp',
  'xcomp',
  'acl',
  'acl:relcl',
  'parataxis',
};

const _phraseRelations = <String>{
  'advmod',
  'appos',
  'dislocated',
  'obl',
  'vocative',
};

const _attachmentLexemes = <String>{
  'of',
  'in',
  'on',
  'at',
  'by',
  'with',
  'from',
  'to',
  'for',
  'between',
  'beneath',
  'under',
  'over',
  'round',
  'through',
  'into',
  'upon',
  'across',
  'like',
  'up',
  'down',
  'out',
  'off',
  'back',
  'away',
  'forth',
};
