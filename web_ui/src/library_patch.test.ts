import { describe, expect, it } from 'vitest';

import { applyEntityPatch, mergePictureBookPageImage } from './App';
import type { PictureBookState } from './types';

describe('library patch reducer', () => {
  it('upserts and deletes by id while preserving retained order', () => {
    const initial = [
      { id: 1, title: 'one' },
      { id: 2, title: 'two' },
    ];
    const updated = applyEntityPatch(
      initial,
      [
        { id: 2, title: 'two updated' },
        { id: 3, title: 'three' },
      ],
      [1],
    );

    expect(updated).toEqual([
      { id: 2, title: 'two updated' },
      { id: 3, title: 'three' },
    ]);
  });

  it('is idempotent and lets removals win over simultaneous upserts', () => {
    const initial = [{ id: 1, title: 'one' }];
    const once = applyEntityPatch(initial, [{ id: 2, title: 'two' }], [1], true);
    const twice = applyEntityPatch(once, [{ id: 2, title: 'two' }], [1], true);
    const removed = applyEntityPatch(twice, [{ id: 2, title: 'ignored' }], [2], true);

    expect(once).toEqual([{ id: 2, title: 'two' }]);
    expect(twice).toEqual(once);
    expect(removed).toEqual([]);
  });

  it('keeps batch import order when appending new entities', () => {
    const imported = Array.from({ length: 40 }, (_, index) => ({
      id: index + 10,
      title: `chapter-${index + 1}`,
    }));

    expect(applyEntityPatch([], imported, []).map((item) => item.id)).toEqual(
      imported.map((item) => item.id),
    );
  });
});

describe('picture-book revision reducer', () => {
  it('drops a late image response from an obsolete revision', () => {
    const state: PictureBookState = {
      articleId: 7,
      enabled: true,
      status: 'ready',
      pages: [{
        pageIndex: 0,
        sentenceStartIndex: 0,
        sentenceEndIndex: 1,
        hasImage: true,
        imageRevision: 'revision-new',
        status: 'ready',
      }],
    };

    expect(mergePictureBookPageImage(state, {
      articleId: 7,
      pageIndex: 0,
      variant: 'display',
      imageRevision: 'revision-old',
      imageUri: 'data:image/png;base64,STALE',
    })).toBe(state);
  });
});
