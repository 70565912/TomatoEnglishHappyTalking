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

/// Closed-class particle shells used when UD mis-tags a phrasal particle as
/// mark/advmod of a verbal complement (`go on listening`) instead of
/// `compound:prt`. Not a book/word exception list: topology still requires
/// the marked verb to be headed by the left predicate.
const _phrasalParticleLexemes = <String>{
  'on',
  'off',
  'up',
  'out',
  'away',
  'back',
  'down',
  'over',
  'along',
  'around',
  'through',
  'ahead',
  'forth',
};
