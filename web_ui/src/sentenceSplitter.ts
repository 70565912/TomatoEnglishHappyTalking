const TARGET_MIN_WORDS = 8;
const TARGET_MAX_WORDS = 14;
const HARD_MAX_WORDS = 16;
const HARD_MAX_CHARS = 90;
const MIN_TAIL_WORDS = 4;

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

const CONNECTORS = new Set([
  'and',
  'but',
  'or',
  'so',
  'then',
  'because',
  'when',
  'while',
  'after',
  'before',
  'if',
  'that',
  'which',
  'who',
  'where',
]);

export function splitSentences(text: string): string[] {
  const cleaned = normalizeArticleText(text);
  if (!cleaned) return [];

  return splitSentenceCandidates(cleaned)
    .flatMap(splitReadingChunks)
    .map((chunk) => chunk.trim())
    .filter(Boolean);
}

function normalizeArticleText(text: string): string {
  return text
    .split(/\r?\n/g)
    .map((line) => line.replace(/[ \t]+/g, ' ').trim())
    .filter((line) => line.length > 0 && !isImportedHeadingLine(line))
    .map(stripCjkPrefix)
    .filter((line) => line.length > 0 && !isImportedHeadingLine(line))
    .join(' ')
    .replace(/[ \t\r\n]+/g, ' ')
    .trim();
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
  return looksLikeTitle;
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

    if (lookahead >= cleaned.length || /\s/.test(cleaned[lookahead])) {
      const sentence = buffer.trim();
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

function splitReadingChunks(sentence: string): string[] {
  const tokens = words(sentence);
  if (tokens.length === 0) return [];
  if (tokens.length <= HARD_MAX_WORDS && sentence.length <= HARD_MAX_CHARS) {
    return [sentence.trim()];
  }

  const chunks: string[] = [];
  let start = 0;
  while (start < tokens.length) {
    const end = chooseChunkEnd(tokens, start);
    chunks.push(tokens.slice(start, end).join(' ').trim());
    start = end;
  }

  return mergeTinyChunks(chunks);
}

function chooseChunkEnd(tokens: string[], start: number): number {
  const remaining = tokens.length - start;
  const remainingText = tokens.slice(start).join(' ');
  if (remaining <= HARD_MAX_WORDS && remainingText.length <= HARD_MAX_CHARS) {
    return tokens.length;
  }

  const hardEnd = Math.min(start + HARD_MAX_WORDS, tokens.length);
  const minEnd = Math.min(start + TARGET_MIN_WORDS, tokens.length);

  for (let end = hardEnd; end > minEnd; end -= 1) {
    if (chunkText(tokens, start, end).length > HARD_MAX_CHARS) continue;
    if (isClauseBreak(tokens[end - 1])) return avoidTinyTail(tokens, start, end);
  }

  for (let end = Math.min(start + TARGET_MAX_WORDS, tokens.length); end > minEnd; end -= 1) {
    if (chunkText(tokens, start, end).length > HARD_MAX_CHARS) continue;
    if (end < tokens.length && isConnector(tokens[end])) return avoidTinyTail(tokens, start, end);
    if (isConnector(tokens[end - 1]) && end - start > TARGET_MIN_WORDS) {
      return avoidTinyTail(tokens, start, end);
    }
  }

  let end = Math.min(start + TARGET_MAX_WORDS, tokens.length);
  while (end > minEnd && chunkText(tokens, start, end).length > HARD_MAX_CHARS) {
    end -= 1;
  }
  if (end <= start) return Math.min(start + HARD_MAX_WORDS, tokens.length);
  return avoidTinyTail(tokens, start, end);
}

function avoidTinyTail(tokens: string[], start: number, end: number): number {
  const tailWords = tokens.length - end;
  if (tailWords === 0 || tailWords >= MIN_TAIL_WORDS) return end;

  const expandedText = chunkText(tokens, start, tokens.length);
  if (tokens.length - start <= HARD_MAX_WORDS + 2 && expandedText.length <= HARD_MAX_CHARS + 16) {
    return tokens.length;
  }

  const shortened = Math.max(start + TARGET_MIN_WORDS, end - (MIN_TAIL_WORDS - tailWords));
  return shortened > start ? shortened : end;
}

function mergeTinyChunks(chunks: string[]): string[] {
  const merged: string[] = [];
  chunks.forEach((chunk) => {
    if (merged.length > 0 && words(chunk).length < MIN_TAIL_WORDS) {
      const previous = merged.pop() ?? '';
      const joined = `${previous} ${chunk}`.trim();
      if (words(joined).length <= HARD_MAX_WORDS + 2 && joined.length <= HARD_MAX_CHARS + 16) {
        merged.push(joined);
        return;
      }
      merged.push(previous, chunk);
      return;
    }
    merged.push(chunk);
  });
  return merged;
}

function words(text: string): string[] {
  return text.split(/\s+/).map((token) => token.trim()).filter(Boolean);
}

function chunkText(tokens: string[], start: number, end: number): string {
  return tokens.slice(start, end).join(' ');
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

function isClauseBreak(token: string): boolean {
  return /[,;:，；：]$/.test(token) || token.endsWith('—') || token.endsWith('–');
}

function isConnector(token: string): boolean {
  const normalized = token.replace(/^[^A-Za-z]+|[^A-Za-z]+$/g, '').toLowerCase();
  return CONNECTORS.has(normalized);
}
