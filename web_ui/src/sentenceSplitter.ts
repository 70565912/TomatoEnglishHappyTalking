/**
 * Web UI read-aloud chunk splitter — must stay aligned with `NlpService.splitSentences`.
 *
 * Design goals:
 * - Output practice/listening/song lyric chunks, not linguistic sentence boundaries.
 * - Keep chunks readable: not too short (no 1–3 word fragments or orphan preposition tails),
 *   not too long (comfort ~20 words, hard max 32).
 * - Use generic punctuation/quote/dash/word-window rules only; never hard-code story titles or chapter ids.
 */
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
  const paragraphs = normalizeArticleParagraphs(text);
  if (paragraphs.length === 0) return [];

  return paragraphs.flatMap((paragraph) => {
    const chunks = splitSentenceCandidates(paragraph)
      .flatMap(splitLongReadAloudChunk)
      .map((sentence) => sentence.trim())
      .filter(Boolean);
    return mergeReadAloudContinuations(chunks);
  });
}

function normalizeArticleParagraphs(text: string): string[] {
  const paragraphs: string[] = [];
  const currentLines: string[] = [];

  const flushParagraph = () => {
    if (currentLines.length === 0) return;
    const paragraph = normalizeInWordHyphens(currentLines.join(' ').replace(/[ \t\r\n]+/g, ' ').trim());
    if (paragraph) paragraphs.push(paragraph);
    currentLines.length = 0;
  };

  for (const rawLine of text.split(/\r?\n/g)) {
    let line = rawLine.replace(/[ \t]+/g, ' ').trim();
    if (!line) {
      flushParagraph();
      continue;
    }
    if (isImportedHeadingLine(line)) continue;
    line = stripCjkPrefix(line);
    if (line && !isImportedHeadingLine(line)) {
      currentLines.push(normalizeInWordHyphens(line));
    }
  }
  flushParagraph();

  return paragraphs;
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

type BreakKind = 'strong' | 'comma' | 'connector' | 'directQuote';

type PhraseBreak = {
  index: number;
  kind: BreakKind;
};

const TARGET_PHRASE_MIN_WORDS = 10;
const TARGET_PHRASE_MAX_WORDS = 24;
const HARD_PHRASE_MAX_WORDS = 32;
const COMFORT_PHRASE_MAX_WORDS = 20;
const SHORT_CONNECTOR_MIN_WORDS = 6;
const QUOTE_CONTINUATION_MIN_WORDS = 14;
const TINY_FRAGMENT_MAX_WORDS = 5;
const ORPHAN_TAIL_MAX_WORDS = 12;

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
    const requiredBreak = requiredPhraseBreak(trimmed, start);
    if (restWordCount <= COMFORT_PHRASE_MAX_WORDS && requiredBreak == null) {
      chunks.push(rest);
      break;
    }

    const breakIndex = requiredBreak ?? choosePhraseBreak(trimmed, start);
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

function choosePhraseBreak(text: string, start: number): number {
  const breaks = phraseBreaks(text, start);
  let fallbackBeforeHard: PhraseBreak | null = null;
  let fallbackStrongBeforeHard: PhraseBreak | null = null;
  let bestStrong: PhraseBreak | null = null;
  let bestAny: PhraseBreak | null = null;

  for (const phraseBreak of breaks) {
    const current = text.slice(start, phraseBreak.index).trim();
    const count = words(current).length;
    if (count > HARD_PHRASE_MAX_WORDS) break;
    if (count >= SHORT_CONNECTOR_MIN_WORDS) {
      fallbackBeforeHard = phraseBreak;
      if (phraseBreak.kind === 'strong' || phraseBreak.kind === 'directQuote') {
        fallbackStrongBeforeHard = phraseBreak;
      }
    }

    const remainingText = text.slice(phraseBreak.index).trim();
    const remaining = words(remainingText).length;
    if (remaining < 4) continue;
    if (wouldCreateOrphanTail(remainingText)) continue;
    if (count >= TARGET_PHRASE_MIN_WORDS && count <= TARGET_PHRASE_MAX_WORDS) {
      if (phraseBreak.kind === 'strong') {
        if (!bestStrong || words(text.slice(start, bestStrong.index).trim()).length < count) {
          bestStrong = phraseBreak;
        }
      }
      if (!bestAny || words(text.slice(start, bestAny.index).trim()).length < count) {
        bestAny = phraseBreak;
      }
    }
  }

  if (bestStrong) return bestStrong.index;
  if (bestAny) return bestAny.index;
  if (fallbackStrongBeforeHard) return fallbackStrongBeforeHard.index;
  if (fallbackBeforeHard) return fallbackBeforeHard.index;
  return wordBoundaryAfterWords(text, start, TARGET_PHRASE_MAX_WORDS);
}

function requiredPhraseBreak(text: string, start: number): number | null {
  for (const phraseBreak of phraseBreaks(text, start)) {
    if (phraseBreak.kind !== 'directQuote') continue;
    const current = text.slice(start, phraseBreak.index).trim();
    const remaining = text.slice(phraseBreak.index).trim();
    const currentWords = words(current).length;
    // Only force a pre-quote split when the prose before the quote is already
    // a comfortable read-aloud chunk; otherwise split that narration first.
    if (
      currentWords >= SHORT_CONNECTOR_MIN_WORDS &&
      currentWords <= TARGET_PHRASE_MAX_WORDS &&
      words(remaining).length >= 4
    ) {
      return phraseBreak.index;
    }
  }
  return null;
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
      continue;
    }
    if ((ch === '"' || ch === '“') && shouldBreakBeforeDirectQuote(text, start, index)) {
      breaks.push({ index, kind: 'directQuote' });
    }
  }
  breaks.push(...connectorBreaks(text, start));
  return breaks.sort((a, b) => a.index - b.index);
}

function connectorBreaks(text: string, start: number): PhraseBreak[] {
  const rest = text.slice(start);
  return [...rest.matchAll(/\s+(?:so that|because|while|when|before|after|although|though)\b/gi)]
    .map((match) => ({ index: start + (match.index ?? 0), kind: 'connector' as const }));
}

function shouldBreakBeforeDirectQuote(text: string, start: number, index: number): boolean {
  if (index <= start) return false;
  const current = text.slice(start, index).trim();
  if (words(current).length < SHORT_CONNECTOR_MIN_WORDS) return false;

  const previous = previousNonWhitespace(text, index - 1);
  if (previous < start) return false;
  if (!/[A-Za-z0-9,;:]/.test(text[previous]) && !isClosingPunctuation(text[previous])) {
    return false;
  }

  const next = nextNonWhitespace(text, index + 1);
  if (next >= text.length) return false;
  return /[A-Z]/.test(text[next]);
}

function consumeClosingPunctuation(text: string, index: number): number {
  let cursor = index;
  while (cursor < text.length && isClosingPunctuation(text[cursor])) {
    cursor += 1;
  }
  return cursor;
}

function wordBoundaryAfterWords(text: string, start: number, count: number): number {
  const matches = [...text.slice(start).matchAll(/[A-Za-z][A-Za-z'’-]*(?:-[A-Za-z][A-Za-z'’-]*)*/g)];
  if (matches.length <= count) return text.length;
  let matchIndex = count - 1;
  let match = matches[matchIndex];
  let end = start + (match.index ?? 0) + match[0].length;
  while (wouldEndAtProtectedPeriod(text, end) && matchIndex + 1 < matches.length) {
    matchIndex += 1;
    match = matches[matchIndex];
    end = start + (match.index ?? 0) + match[0].length;
  }
  const nextSpace = text.indexOf(' ', end);
  return nextSpace > end ? nextSpace : consumeClosingPunctuation(text, end);
}

function wouldEndAtProtectedPeriod(text: string, wordEnd: number): boolean {
  let cursor = wordEnd;
  while (cursor < text.length && isClosingPunctuation(text[cursor])) {
    cursor += 1;
  }
  if (cursor >= text.length || text[cursor] !== '.') return false;
  const before = text.slice(0, wordEnd).trimEnd();
  const lastWord = before
    .split(/\s+/)
    .at(-1)
    ?.replace(/^[\"“”]+/g, '')
    .replace(/["”’)\]}》]+$/g, '')
    .toLowerCase() ?? '';
  return ABBREVIATIONS.has(lastWord) || /^[a-z]$/.test(lastWord);
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
  const lastWord = words(current).at(-1)
    ?.replace(/^[\"“”]+/g, '')
    .replace(/[.!?。！？"”’)\]}》]+$/g, '')
    .toLowerCase() ?? '';
  return ABBREVIATIONS.has(lastWord) || /^[a-z]$/.test(lastWord);
}

function shouldKeepReadingThroughSentenceEnd(current: string, text: string, lookahead: number): boolean {
  if (hasUnclosedDoubleQuote(current)) {
    const next = nextNonWhitespace(text, lookahead);
    if (next >= text.length) return true;
    if (/[a-z]/.test(text[next])) return true;
    const tail = text.slice(lookahead).trim();
    if (isSameQuoteShortTail(tail)) return true;
    return words(current).length < QUOTE_CONTINUATION_MIN_WORDS;
  }

  const next = nextNonWhitespace(text, lookahead);
  if (next >= text.length) return false;

  return /[a-z]/.test(text[next]);
}

function hasUnclosedDoubleQuote(text: string): boolean {
  const straightQuotes = (text.match(/"/g) ?? []).length;
  if (straightQuotes % 2 === 1) {
    const trimmed = text.trimEnd();
    const lastQuote = trimmed.lastIndexOf('"');
    if (lastQuote >= 0) {
      let cursor = lastQuote + 1;
      while (cursor < trimmed.length && isClosingPunctuation(trimmed[cursor])) {
        cursor += 1;
      }
      if (cursor >= trimmed.length) return false;
    }
    return true;
  }

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

function previousNonWhitespace(text: string, start: number): number {
  let index = start;
  while (index >= 0 && /\s/.test(text[index])) {
    index -= 1;
  }
  return index;
}

function mergeReadAloudContinuations(chunks: string[]): string[] {
  const merged: string[] = [];
  for (const rawChunk of chunks) {
    const chunk = rawChunk.trim();
    if (!chunk) continue;
    const previous = merged.at(-1);
    if (previous && shouldMergeWithPrevious(previous, chunk)) {
      merged[merged.length - 1] = `${previous} ${chunk}`.replace(/\s+/g, ' ').trim();
    } else {
      merged.push(chunk);
    }
  }
  return mergeTinyQuoteTails(merged);
}

function mergeTinyQuoteTails(chunks: string[]): string[] {
  const merged: string[] = [];
  for (const rawChunk of chunks) {
    const chunk = rawChunk.trim();
    if (!chunk) continue;
    const previous = merged.at(-1);
    if (
      previous &&
      endsWithFinalSentencePunctuation(previous) &&
      hasUnclosedDoubleQuote(previous) &&
      words(chunk).length <= TINY_FRAGMENT_MAX_WORDS &&
      isSameQuoteShortTail(chunk) &&
      words(`${previous} ${chunk}`).length <= HARD_PHRASE_MAX_WORDS
    ) {
      merged[merged.length - 1] = `${previous} ${chunk}`.replace(/\s+/g, ' ').trim();
      continue;
    }
    merged.push(chunk);
  }
  return merged;
}

function shouldMergeWithPrevious(previous: string, current: string): boolean {
  const combinedWords = words(`${previous} ${current}`).length;
  if (combinedWords > HARD_PHRASE_MAX_WORDS) return false;
  if (hasUnclosedDoubleQuote(previous)) {
    if (
      words(current).length <= TINY_FRAGMENT_MAX_WORDS &&
      isSameQuoteShortTail(current) &&
      combinedWords <= HARD_PHRASE_MAX_WORDS
    ) {
      return true;
    }
    return combinedWords <= TARGET_PHRASE_MAX_WORDS;
  }
  if (endsWithEmDash(previous)) {
    return shouldMergeEmDashContinuation(current);
  }
  if (endsWithDanglingReadAloudPhrase(previous)) return true;
  if (endsWithShortCommaPhrase(previous)) {
    return combinedWords <= TARGET_PHRASE_MAX_WORDS;
  }
  if (isShortQuotedFragment(previous)) {
    return combinedWords <= TARGET_PHRASE_MAX_WORDS;
  }
  if (startsWithLowercaseConnector(current) && !endsWithFinalSentencePunctuation(previous)) {
    if (endsWithStrongPhrasePunctuation(previous) && words(previous).length >= TARGET_PHRASE_MIN_WORDS) {
      return false;
    }
    return combinedWords <= TARGET_PHRASE_MAX_WORDS;
  }
  return false;
}

function startsWithLowercaseConnector(text: string): boolean {
  return /^(?:and|but|or|so|for|yet|then|because|while|when|as|though|although|which|who|that)\b/.test(text.trim());
}

function endsWithEmDash(text: string): boolean {
  const trimmed = text.trim();
  return trimmed.endsWith('—') || trimmed.endsWith('–');
}

function shouldMergeEmDashContinuation(current: string): boolean {
  const currentTrim = current.trim();
  if (!currentTrim) return false;
  if (/^["“]/.test(currentTrim)) return true;
  const firstLetter = leadingContentLetter(currentTrim);
  if (firstLetter && /[a-z]/.test(firstLetter)) {
    return words(currentTrim).length < TARGET_PHRASE_MIN_WORDS;
  }
  if (words(currentTrim).length <= TINY_FRAGMENT_MAX_WORDS) return true;
  return false;
}

function leadingContentLetter(text: string): string | null {
  const match = text.match(/[A-Za-z]/);
  return match?.[0] ?? null;
}

function isSameQuoteShortTail(text: string): boolean {
  const fragment = sameUtteranceTailPrefix(text);
  if (!fragment || words(fragment).length > TINY_FRAGMENT_MAX_WORDS || startsWithNewSpeakerAttribution(fragment)) {
    return false;
  }
  return true;
}

function sameUtteranceTailPrefix(text: string): string {
  const trimmed = text.trim();
  for (let i = 0; i < trimmed.length; i += 1) {
    const ch = trimmed[i];
    if (ch === '"' || ch === '”') {
      return trimmed.slice(0, i + 1).trim();
    }
  }
  return trimmed;
}

function startsWithNewSpeakerAttribution(text: string): boolean {
  return /^(?:said|cried|shouted|asked|thought|answered|replied|muttered|whispered|called|went on)\b/i.test(
    text.trim(),
  );
}

function wouldCreateOrphanTail(remaining: string): boolean {
  const remainingWords = words(remaining).length;
  if (remainingWords >= ORPHAN_TAIL_MAX_WORDS) return false;
  return /^(?:with|and|in|on|at|to|for|from|into|upon|about|like|as|but|or|so|yet|nor|that|which|who)\s+/i.test(
    remaining.trim(),
  );
}

function endsWithDanglingReadAloudPhrase(text: string): boolean {
  const trimmed = text.trim();
  if (trimmed.endsWith('-') && !trimmed.endsWith('—') && !trimmed.endsWith('–')) {
    return true;
  }
  return /\b(?:a|an|the|and|or|but|as|if|to|of|for|with|from|into|upon|about|like|than|that|which|who|what|how|why|where|when|me|my|your|his|her|their|our)\s*["”’)\]}》]*$/i.test(trimmed);
}

function endsWithShortCommaPhrase(text: string): boolean {
  const trimmed = text.trim();
  return words(trimmed).length < TARGET_PHRASE_MIN_WORDS && /,["”’)\]}》]*$/.test(trimmed);
}

function isShortQuotedFragment(text: string): boolean {
  const trimmed = text.trim();
  if (words(trimmed).length >= TARGET_PHRASE_MIN_WORDS) return false;
  if (!/^["'“‘]/.test(trimmed)) return false;
  return !endsWithFinalSentencePunctuation(trimmed) || /[,'"“‘][^"'“”‘’]*[.!?。！？]$/.test(trimmed);
}

function endsWithFinalSentencePunctuation(text: string): boolean {
  return /[.!?。！？]["”’)\]}》]*$/.test(text.trim());
}

function endsWithStrongPhrasePunctuation(text: string): boolean {
  return /[;:—–]["”’)\]}》]*$/.test(text.trim());
}
