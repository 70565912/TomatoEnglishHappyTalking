import type { ListeningItem } from './types';

export function isHiddenListeningSentence(text: string): boolean {
  return text.trim().length === 0;
}

export function isHiddenListeningItem(item: Pick<ListeningItem, 'english' | 'hidden'>): boolean {
  return item.hidden === true || isHiddenListeningSentence(item.english);
}

export function visibleListeningItems(items: ListeningItem[]): ListeningItem[] {
  return items.filter((item) => !isHiddenListeningItem(item));
}

export function resolveListeningItemBySlotIndex(
  items: ListeningItem[],
  slotIndex: number,
): ListeningItem | undefined {
  return items.find((item) => item.index === slotIndex);
}

export function visibleItemPosition(items: ListeningItem[], slotIndex: number): number {
  const visible = visibleListeningItems(items);
  return visible.findIndex((item) => item.index === slotIndex);
}

export function visibleSentenceCountFromItems(items: ListeningItem[]): number {
  return visibleListeningItems(items).length;
}

export function firstVisibleSlotIndex(items: ListeningItem[]): number | null {
  const visible = visibleListeningItems(items);
  return visible.length > 0 ? visible[0].index : null;
}

/** 1-based position of [slotIndex] among visible sentences. */
export function visiblePositionForSlotIndex(sentences: string[], slotIndex: number): number {
  if (slotIndex < 0 || sentences.length === 0) {
    return 0;
  }
  let position = 0;
  const last = slotIndex < sentences.length ? slotIndex : sentences.length - 1;
  for (let index = 0; index <= last; index += 1) {
    if (!isHiddenListeningSentence(sentences[index] ?? '')) {
      position += 1;
    }
  }
  return position;
}
