const ABBREVIATIONS = new Set([
  'mr',
  'mrs',
  'ms',
  'dr',
  'prof',
  'sr',
  'jr',
  'rev',
  'vs',
  'etc',
  'fig',
  'no',
  'vol',
  'dept',
  'approx',
  'jan',
  'feb',
  'mar',
  'apr',
  'jun',
  'jul',
  'aug',
  'sep',
  'oct',
  'nov',
  'dec',
  'u.s',
  'u.k',
  'e.g',
  'i.e',
  'a.m',
  'p.m',
  'st',
]);

export function splitSentences(text: string): string[] {
  const cleaned = normalizeArticleText(text);
  if (!cleaned) return [];

  return splitSentenceCandidates(cleaned)
    .flatMap(splitLongReadAloudChunk)
    .map((sentence) => sentence.trim())
    .filter(Boolean);
}

function normalizeArticleText(text: string): string {
  return text
    .split(/\r?\n/g)
    .map((line) => line.replace(/[ \t]+/g, ' ').trim())
    .filter((line) => line.length > 0 && !isImportedHeadingLine(line))
    .map(stripCjkPrefix)
    .filter((line) => line.length > 0 && !isImportedHeadingLine(line))
    .map(normalizeInWordHyphens)
    .join(' ')
    .replace(/[ \t\r\n]+/g, ' ')
    .replace(/([A-Za-z])\s*-\s*([A-Za-z])/g, '$1-$2')
    .trim();
}

function normalizeInWordHyphens(text: string): string {
  return text.replace(/([A-Za-z])\s*-\s*([A-Za-z])/g, '$1-$2');
}

function isImportedHeadingLine(line: string): boolean {
  const normalized = line.trim();
  if (!normalized) return true;
  if (/^(?:E|EP|Episode)\s*\d+$/i.test(normalized)) return true;

  const hasLatin = /[A-Za-z]/.test(normalized);
  const hasCjk = /[\u3400-\u9FFF]/.test(normalized);
  if (hasCjk && !hasLatin) return true;

  const wordCount = words(normalized).length;
  const isSentenceLike = /[.!?。！？"”]$/.test(normalized);
  const hasEpisodeMarker = /\bEpisod(?:e)?\s*\d+\b/i.test(normalized);
  if (hasEpisodeMarker && !isSentenceLike) return true;
  if (hasCjk && hasEpisodeMarker) return true;

  const isChapterHeading = /\bChapter\b/i.test(normalized) && wordCount <= 8 && !isSentenceLike;
  if (isChapterHeading) return true;

  const looksLikeTitle = wordCount <= 7 && !isSentenceLike && /\s-\s/.test(normalized);
  if (looksLikeTitle) return true;

  return looksLikeStandaloneTitle(normalized, wordCount, isSentenceLike);
}

function looksLikeStandaloneTitle(line: string, wordCount: number, isSentenceLike: boolean): boolean {
  if (isSentenceLike || wordCount < 2 || wordCount > 7) return false;
  if (/[,;:!?。！？]/.test(line)) return false;

  const tokens = line.match(/[A-Za-z][A-Za-z'’-]*(?:-[A-Za-z][A-Za-z'’-]*)*/g) ?? [];
  if (tokens.length !== wordCount) return false;

  return tokens.every(isTitleWord);
}

function isTitleWord(token: string): boolean {
  const normalized = token.toLowerCase();
  const smallTitleWords = new Set([
    'a',
    'an',
    'and',
    'as',
    'at',
    'by',
    'for',
    'from',
    'in',
    'of',
    'on',
    'or',
    'the',
    'to',
    'with',
  ]);
  return smallTitleWords.has(normalized) || /^[A-Z]/.test(token);
}

function stripCjkPrefix(line: string): string {
  if (!/[\u3400-\u9FFF]/.test(line) || !/[A-Za-z]/.test(line)) return line;
  const latinIndex = line.search(/[A-Za-z]/);
  return latinIndex >= 0 ? line.slice(latinIndex).trimStart() : '';
}

function splitSentenceCandidates(cleaned: string): string[] {
  const candidates: string[] = [];
  let buffer = '';

  for (let index = 0; index < cleaned.length; index += 1) {
    const ch = cleaned[index];
    buffer += ch;

    if (!isSentenceEnd(ch)) continue;
    if (ch === '.' && isDecimalPoint(cleaned, index)) continue;
    if (ch === '.' && isProtectedPeriod(buffer.trim())) continue;

    let lookahead = index + 1;
    while (lookahead < cleaned.length && isClosingPunctuation(cleaned[lookahead])) {
      buffer += cleaned[lookahead];
      index = lookahead;
      lookahead += 1;
    }

    const currentWithClosers = buffer.trim();
    if (shouldKeepReadingThroughSentenceEnd(currentWithClosers, cleaned, lookahead)) {
      continue;
    }

    if (lookahead >= cleaned.length || /\s/.test(cleaned[lookahead])) {
      const sentence = currentWithClosers;
      if (sentence) candidates.push(sentence);
      buffer = '';

      while (lookahead < cleaned.length && /\s/.test(cleaned[lookahead])) {
        index = lookahead;
        lookahead += 1;
      }
    }
  }

  const remaining = buffer.trim();
  if (remaining) candidates.push(remaining);
  return candidates.length > 0 ? candidates : [cleaned];
}

type BreakKind = 'strong' | 'comma';

type PhraseBreak = {
  index: number;
  kind: BreakKind;
};

const TARGET_PHRASE_MIN_WORDS = 8;
const TARGET_PHRASE_MAX_WORDS = 16;
const HARD_PHRASE_MAX_WORDS = 22;
const SHORT_CONNECTOR_MIN_WORDS = 5;

function splitLongReadAloudChunk(sentence: string): string[] {
  const trimmed = sentence.trim();
  if (!trimmed) return [trimmed];

  const chunks: string[] = [];
  let start = 0;

  while (start < trimmed.length) {
    const rest = trimmed.slice(start).trimStart();
    start += trimmed.slice(start).length - rest.length;
    if (!rest) break;

    const restWordCount = words(rest).length;
    const optionalBreak = chooseOptionalPhraseBreak(trimmed, start);
    if (restWordCount <= HARD_PHRASE_MAX_WORDS && optionalBreak == null) {
      chunks.push(rest);
      break;
    }

    const breakIndex =
      restWordCount <= HARD_PHRASE_MAX_WORDS && optionalBreak != null
        ? optionalBreak
        : choosePhraseBreak(trimmed, start);
    if (breakIndex <= start || breakIndex >= trimmed.length) {
      chunks.push(rest);
      break;
    }

    const chunk = trimmed.slice(start, breakIndex).trim();
    if (chunk) chunks.push(chunk);
    start = breakIndex;
  }

  return chunks.length > 0 ? chunks : [trimmed];
}

function chooseOptionalPhraseBreak(text: string, start: number): number | null {
  for (const phraseBreak of phraseBreaks(text, start)) {
    const current = text.slice(start, phraseBreak.index).trim();
    const count = words(current).length;
    const remaining = words(text.slice(phraseBreak.index).trim()).length;
    if (remaining < 4) continue;

    if (phraseBreak.kind === 'strong' && count >= SHORT_CONNECTOR_MIN_WORDS) {
      return phraseBreak.index;
    }
    if (count >= TARGET_PHRASE_MIN_WORDS && count <= TARGET_PHRASE_MAX_WORDS) {
      return phraseBreak.index;
    }
    if (
      count >= SHORT_CONNECTOR_MIN_WORDS &&
      nextChunkStartsWithConnector(text, phraseBreak.index)
    ) {
      return phraseBreak.index;
    }
  }
  return null;
}

function choosePhraseBreak(text: string, start: number): number {
  const breaks = phraseBreaks(text, start);
  let fallbackBeforeHard: PhraseBreak | null = null;

  for (const phraseBreak of breaks) {
    const current = text.slice(start, phraseBreak.index).trim();
    const count = words(current).length;
    if (count > HARD_PHRASE_MAX_WORDS) break;
    fallbackBeforeHard = phraseBreak;

    if (phraseBreak.kind === 'strong' && count >= SHORT_CONNECTOR_MIN_WORDS) {
      return phraseBreak.index;
    }
    if (count >= TARGET_PHRASE_MIN_WORDS && count <= TARGET_PHRASE_MAX_WORDS) {
      return phraseBreak.index;
    }
    if (
      count >= SHORT_CONNECTOR_MIN_WORDS &&
      nextChunkStartsWithConnector(text, phraseBreak.index)
    ) {
      return phraseBreak.index;
    }
  }

  if (fallbackBeforeHard) return fallbackBeforeHard.index;
  return wordBoundaryAfterWords(text, start, TARGET_PHRASE_MAX_WORDS);
}

function phraseBreaks(text: string, start: number): PhraseBreak[] {
  const breaks: PhraseBreak[] = [];
  for (let index = start; index < text.length; index += 1) {
    const ch = text[index];
    if (ch === ';' || ch === ':' || ch === '—' || ch === '–') {
      breaks.push({ index: consumeClosingPunctuation(text, index + 1), kind: 'strong' });
      continue;
    }
    if (ch === ',' && !hasUnclosedDoubleQuote(text.slice(start, index + 1))) {
      breaks.push({ index: consumeClosingPunctuation(text, index + 1), kind: 'comma' });
    }
  }
  return breaks;
}

function consumeClosingPunctuation(text: string, index: number): number {
  let cursor = index;
  while (cursor < text.length && isClosingPunctuation(text[cursor])) {
    cursor += 1;
  }
  return cursor;
}

function nextChunkStartsWithConnector(text: string, index: number): boolean {
  const rest = text.slice(index).trimStart();
  return /^(?:and|but|or|so|for|yet|then|because|while|when|as|though|although|which|who|that)\b/i.test(rest);
}

function wordBoundaryAfterWords(text: string, start: number, count: number): number {
  const matches = [...text.slice(start).matchAll(/[A-Za-z][A-Za-z'’-]*(?:-[A-Za-z][A-Za-z'’-]*)*/g)];
  if (matches.length <= count) return text.length;
  const match = matches[count - 1];
  const end = start + (match.index ?? 0) + match[0].length;
  const nextSpace = text.indexOf(' ', end);
  return nextSpace > end ? nextSpace : end;
}

function words(text: string): string[] {
  return text.split(/\s+/).map((token) => token.trim()).filter(Boolean);
}

function isSentenceEnd(ch: string): boolean {
  return ch === '.' || ch === '!' || ch === '?' || ch === '。' || ch === '！' || ch === '？';
}

function isClosingPunctuation(ch: string): boolean {
  return '\'"”’)]}》'.includes(ch);
}

function isDecimalPoint(text: string, index: number): boolean {
  if (index === 0 || index + 1 >= text.length) return false;
  return /\d/.test(text[index - 1]) && /\d/.test(text[index + 1]);
}

function isProtectedPeriod(current: string): boolean {
  const lastWord = words(current).at(-1)?.replace(/[.!?。！？"”’)\]}》]+$/g, '').toLowerCase() ?? '';
  return ABBREVIATIONS.has(lastWord) || /^[a-z]$/.test(lastWord);
}

function shouldKeepReadingThroughSentenceEnd(current: string, text: string, lookahead: number): boolean {
  if (hasUnclosedDoubleQuote(current)) return true;

  const next = nextNonWhitespace(text, lookahead);
  if (next >= text.length) return false;

  return /[a-z]/.test(text[next]);
}

function hasUnclosedDoubleQuote(text: string): boolean {
  const straightQuotes = (text.match(/"/g) ?? []).length;
  if (straightQuotes % 2 === 1) return true;

  const openCurlyQuotes = (text.match(/“/g) ?? []).length;
  const closeCurlyQuotes = (text.match(/”/g) ?? []).length;
  return openCurlyQuotes > closeCurlyQuotes;
}

function nextNonWhitespace(text: string, start: number): number {
  let index = start;
  while (index < text.length && /\s/.test(text[index])) {
    index += 1;
  }
  return index;
}
