import { useEffect, useRef, useState } from 'react';
import { sendNative } from './bridge';
import type {
  PictureBookTransitionFramesPayload,
  RecordingPageTransition,
} from './types';

function normalizePageTransition(value?: string | null): RecordingPageTransition {
  if (
    value === 'crossFade' ||
    value === 'panZoomFade' ||
    value === 'slide' ||
    value === 'pageCurl'
  ) {
    return value;
  }
  return 'none';
}

function usePrefersReducedMotion(): boolean {
  const [reduced, setReduced] = useState(() => {
    if (typeof window === 'undefined' || typeof window.matchMedia !== 'function') {
      return false;
    }
    return window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  });

  useEffect(() => {
    if (typeof window === 'undefined' || typeof window.matchMedia !== 'function') {
      return undefined;
    }
    const media = window.matchMedia('(prefers-reduced-motion: reduce)');
    const onChange = () => setReduced(media.matches);
    onChange();
    media.addEventListener('change', onChange);
    return () => media.removeEventListener('change', onChange);
  }, []);

  return reduced;
}

export function TransitioningPicture({
  src,
  articleId,
  pageIndex,
  objectFit = 'contain',
  transition = 'none',
  className,
  alt = '',
}: {
  src: string;
  articleId?: number | null;
  pageIndex?: number | null;
  objectFit?: 'contain' | 'cover';
  transition?: RecordingPageTransition | string | null;
  className?: string;
  alt?: string;
}) {
  const reduceMotion = usePrefersReducedMotion();
  const pageTransition = normalizePageTransition(transition);
  const animated = !reduceMotion && pageTransition !== 'none';
  const [displaySrc, setDisplaySrc] = useState(src);
  const [frameSrc, setFrameSrc] = useState<string | null>(null);
  const [transitioning, setTransitioning] = useState(false);
  const committedSrcRef = useRef(src);
  const committedPageRef = useRef<number | null>(pageIndex ?? null);
  const generationRef = useRef(0);
  const frameRequestRef = useRef<number | null>(null);
  const completionTimerRef = useRef<number | null>(null);

  const cancelFrameLoop = () => {
    if (frameRequestRef.current !== null) {
      window.cancelAnimationFrame(frameRequestRef.current);
      frameRequestRef.current = null;
    }
    if (completionTimerRef.current !== null) {
      window.clearTimeout(completionTimerRef.current);
      completionTimerRef.current = null;
    }
  };

  const snapTo = (target: string, targetPageIndex: number | null) => {
    generationRef.current += 1;
    cancelFrameLoop();
    committedSrcRef.current = target;
    committedPageRef.current = targetPageIndex;
    setDisplaySrc(target);
    setFrameSrc(null);
    setTransitioning(false);
  };

  useEffect(() => {
    const target = src.trim();
    const targetPageIndex = pageIndex ?? null;
    if (!target) {
      snapTo('', targetPageIndex);
      return undefined;
    }

    if (
      target === committedSrcRef.current &&
      targetPageIndex === committedPageRef.current
    ) {
      return undefined;
    }

    if (
      !animated ||
      articleId == null ||
      targetPageIndex == null ||
      committedPageRef.current == null ||
      targetPageIndex === committedPageRef.current
    ) {
      snapTo(target, targetPageIndex);
      return undefined;
    }

    cancelFrameLoop();
    const generation = ++generationRef.current;
    const fromPageIndex = committedPageRef.current;
    const fromSrc = committedSrcRef.current;
    setFrameSrc(null);
    setDisplaySrc(fromSrc);
    setTransitioning(true);

    void sendNative<PictureBookTransitionFramesPayload>('pictureBook.transitionFrames', {
      articleId,
      fromPageIndex,
      toPageIndex: targetPageIndex,
      pageTransition,
      width: 1280,
      height: 720,
      frameCount: 8,
    })
      .then((payload) => {
        if (generationRef.current !== generation) return;
        const frames = Array.isArray(payload.frames) ? payload.frames : [];
        if (
          frames.length === 0 ||
          payload.fromPageIndex !== fromPageIndex ||
          payload.toPageIndex !== targetPageIndex
        ) {
          snapTo(target, targetPageIndex);
          return;
        }

        const durationMs = Math.max(1, Number(payload.durationMs) || 500);
        setFrameSrc(frames[0]);
        completionTimerRef.current = window.setTimeout(() => {
          if (generationRef.current === generation) {
            snapTo(target, targetPageIndex);
          }
        }, durationMs + 50);
        const startedAt = window.performance.now();
        const tick = (now: number) => {
          if (generationRef.current !== generation) return;
          const elapsed = Math.max(0, now - startedAt);
          const progress = Math.min(1, elapsed / durationMs);
          const frameIndex = Math.min(
            frames.length - 1,
            Math.floor(progress * (frames.length - 1)),
          );
          setFrameSrc(frames[frameIndex]);
          if (progress >= 1) {
            frameRequestRef.current = null;
            snapTo(target, targetPageIndex);
            return;
          }
          frameRequestRef.current = window.requestAnimationFrame(tick);
        };
        frameRequestRef.current = window.requestAnimationFrame(tick);
      })
      .catch(() => {
        if (generationRef.current === generation) {
          snapTo(target, targetPageIndex);
        }
      });

    return () => {
      cancelFrameLoop();
    };
  }, [articleId, animated, pageIndex, pageTransition, src]);

  useEffect(() => () => cancelFrameLoop(), []);

  if (!displaySrc && !frameSrc) {
    return null;
  }

  const stackClassName = ['picture-transition-stack', className].filter(Boolean).join(' ');
  return (
    <div
      className={stackClassName}
      data-object-fit={objectFit}
      data-transition={pageTransition}
      data-transitioning={transitioning ? 'true' : 'false'}
    >
      <img
        className="picture-transition-layer is-visible"
        src={frameSrc ?? displaySrc}
        alt={alt}
        draggable={false}
      />
    </div>
  );
}
