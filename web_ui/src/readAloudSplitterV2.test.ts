import { describe, expect, it } from 'vitest';
import {
  normalizeForRoundTrip,
  splitReadAloudV2,
  wordCount,
} from './readAloudSplitterV2';

function assertCoreGates(source: string, chunks: string[]): void {
  expect(chunks.join(' ').replace(/\s+/g, ' ').trim()).toBe(normalizeForRoundTrip(source));
  expect(Math.max(...chunks.map(wordCount))).toBeLessThanOrEqual(30);
}

describe('read-aloud splitter v2 structural protections', () => {
  it('keeps what the row was about together', () => {
    const source = 'He was bowled over in an instant by the impatient and contemptuous Mole, who trotted along the side of the hedge chaffing the other rabbits as they peeped hurriedly from their holes to see what the row was about.';
    const chunks = splitReadAloudV2(source);
    assertCoreGates(source, chunks);
    expect(chunks.join('\n')).not.toContain('what the row\nwas about');
  });

  it('keeps subject plus modal and modal plus verb together', () => {
    const source = 'Naturally a voluble animal, and always mastered by his imagination, he painted the prospects of the trip and the joys of the open life and the roadside in such glowing colours that the Mole could hardly sit in his chair for excitement.';
    const chunks = splitReadAloudV2(source);
    assertCoreGates(source, chunks);
    expect(chunks.join('\n')).not.toMatch(/the Mole\ncould hardly|could hardly\nsit/);
  });

  it('keeps determiner noun phrase together', () => {
    const source = 'And instead of having an uneasy conscience pricking him and whispering "whitewash!" he somehow could only feel how jolly it was to be the only idle dog among all these busy citizens.';
    const chunks = splitReadAloudV2(source);
    assertCoreGates(source, chunks);
    expect(chunks.join('\n')).not.toContain('to be the\nonly idle dog');
  });

  it('does not cut and after into a dangling connector', () => {
    const source = 'The sunshine struck hot on his fur, soft breezes caressed his heated brow, and after the seclusion of the cellarage he had lived in so long the carol of happy birds fell on his dulled hearing almost like a shout.';
    const chunks = splitReadAloudV2(source);
    assertCoreGates(source, chunks);
    expect(chunks.join('\n')).not.toContain('brow, and\nafter');
  });

  it('preserves abbreviations, decimals, glued sentences, and quotation starts', () => {
    const source = 'Mr. Toad paid 3.5 shillings. "Go now!" he cried.He left."She stayed behind."';
    const chunks = splitReadAloudV2(source);
    assertCoreGates(source, chunks);
    expect(chunks.join(' ')).toContain('Mr. Toad paid 3.5 shillings.');
    expect(chunks.join(' ')).toContain('He left. "She stayed behind."');
  });

  it('splits the long relative sentence before whose without stranding and air', () => {
    const source = 'Something up above was calling him imperiously, and he made for the steep little tunnel which answered in his case to the gravelled carriage-drive owned by animals whose residences are nearer to the sun and air.';
    const chunks = splitReadAloudV2(source);
    assertCoreGates(source, chunks);
    expect(chunks.join('\n')).toContain('animals\nwhose residences are nearer to the sun and air.');
  });

  it('merges consecutive tiny read-aloud units within one paragraph', () => {
    const source = '"Up we go! Up we go!" till at last, pop! his snout came out into the sunlight and he found himself rolling in the warm grass of a great meadow.';
    const chunks = splitReadAloudV2(source);
    assertCoreGates(source, chunks);
    expect(chunks).toEqual([
      '"Up we go! Up we go!" till at last, pop! his snout came out into the sunlight',
      'and he found himself rolling in the warm grass of a great meadow.',
    ]);
  });

  it('merges a short quoted outburst continued by lowercase conjunctions', () => {
    const source = 'It was small wonder, then, that he suddenly flung down his brush on the floor, said, "Bother!" and "O blow!" and also "Hang spring-cleaning!" and bolted out of the house without even waiting to put on his coat.';
    const chunks = splitReadAloudV2(source);
    assertCoreGates(source, chunks);
    expect(chunks.some((chunk) => chunk.includes('"Bother!" and "O blow!" and also "Hang spring-cleaning!"'))).toBe(true);
    expect(chunks).not.toContain('"Bother!"');
    expect(chunks).not.toContain('and "O blow!"');
  });

  it('merges comma-ended short fragments and list continuations', () => {
    const description = 'He led the way to the stable-yard accordingly, the Rat following with a most mistrustful expression; and there, drawn out of the coach-house into the open, they saw a gipsy caravan, shining with newness, painted a canary-yellow picked out with green, and red wheels.';
    const descriptionChunks = splitReadAloudV2(description);
    assertCoreGates(description, descriptionChunks);
    expect(descriptionChunks).toContain('they saw a gipsy caravan, shining with newness, painted a canary-yellow picked out with green, and red wheels.');

    const list = 'Camps, villages, towns, cities!';
    const listChunks = splitReadAloudV2(list);
    assertCoreGates(list, listChunks);
    expect(listChunks).toEqual(['Camps, villages, towns, cities!']);
  });

  it('merges complete short sentences when the paragraph is still below target', () => {
    const source = 'Mole looked up. Rat waved back. Toad laughed loudly.';
    const chunks = splitReadAloudV2(source);
    assertCoreGates(source, chunks);
    expect(chunks).toEqual([source]);
  });

  it('keeps a 22-word paragraph intact but splits 23 words at the sentence pause', () => {
    const comfortableOverflow = 'Mole cleaned the dusty room and packed every brush neatly away. Rat opened the round window and called him toward the sunshine.';
    const comfortableChunks = splitReadAloudV2(comfortableOverflow);
    assertCoreGates(comfortableOverflow, comfortableChunks);
    expect(wordCount(comfortableOverflow)).toBe(22);
    expect(comfortableChunks).toEqual([comfortableOverflow]);

    const excessiveOverflow = 'Mole cleaned the dusty room and packed every brush neatly away. Rat opened the round window and called him into the sunshine outside.';
    const excessiveChunks = splitReadAloudV2(excessiveOverflow);
    assertCoreGates(excessiveOverflow, excessiveChunks);
    expect(wordCount(excessiveOverflow)).toBe(23);
    expect(excessiveChunks).toEqual([
      'Mole cleaned the dusty room and packed every brush neatly away.',
      'Rat opened the round window and called him into the sunshine outside.',
    ]);
  });

  it('does not strand an attribution parenthetical or quoted noun after a determiner', () => {
    const attribution = 'The driver laughed at the proposal, so heartily that the gentleman inquired what the matter was. When he heard, he said, to Toad\'s delight, "Bravo, ma\'am! I like your spirit."';
    const attributionChunks = splitReadAloudV2(attribution);
    assertCoreGates(attribution, attributionChunks);
    expect(attributionChunks.join('\n')).not.toContain('he said,\nto Toad\'s delight');

    const quotedNoun = "The sentries were on the look-out, of course, with their guns and their 'Who comes there?' and all the rest of their nonsense.";
    const quotedNounChunks = splitReadAloudV2(quotedNoun);
    assertCoreGates(quotedNoun, quotedNounChunks);
    expect(quotedNounChunks.join('\n')).not.toContain("their\n'Who comes there?'");
  });

  it('rejoins a short dependent prepositional tail even when its host becomes long', () => {
    const source = 'As he sat on the grass and looked across the river, a dark hole in the bank opposite, just above the water\'s edge, caught his eye, and dreamily he fell to considering what a nice, snug dwelling-place it would make for an animal with few wants and fond of a bijou riverside residence, above flood level and remote from noise and dust.';
    const chunks = splitReadAloudV2(source);
    assertCoreGates(source, chunks);
    expect(chunks.join('\n')).not.toContain('riverside residence,\nabove flood level');
    expect(chunks.join('\n')).not.toContain('fond\nof a bijou');
    expect(chunks.join('\n')).not.toContain('few wants\nand fond of a bijou');
    expect(chunks.join('\n')).not.toContain('bijou riverside\nresidence');
  });
});
