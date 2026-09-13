import { useEffect, useLayoutEffect, useRef, useState, type TransitionEvent } from 'react';
import type { RecordingPageTransition } from './types';

const TRANSITION_MS = 500;

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
  objectFit = 'contain',
  transition = 'none',
  className,
  alt = '',
}: {
  src: string;
  objectFit?: 'contain' | 'cover';
  transition?: RecordingPageTransition | string | null;
  className?: string;
  alt?: string;
}) {
  const reduceMotion = usePrefersReducedMotion();
  const pageTransition = normalizePageTransition(transition);
  const animated = !reduceMotion && pageTransition !== 'none';
  const [currentSrc, setCurrentSrc] = useState(src);
  const [nextSrc, setNextSrc] = useState<string | null>(null);
  const [fading, setFading] = useState(false);
  const currentRef = useRef(src);
  const nextRef = useRef<string | null>(null);
  const targetRef = useRef(src);
  const incomingRef = useRef<HTMLImageElement | null>(null);
  const fadeFrameRef = useRef<number | null>(null);

  const clearFadeFrame = () => {
    if (fadeFrameRef.current !== null) {
      window.cancelAnimationFrame(fadeFrameRef.current);
      fadeFrameRef.current = null;
    }
  };

  const snapTo = (target: string) => {
    clearFadeFrame();
    currentRef.current = target;
    nextRef.current = null;
    setCurrentSrc(target);
    setNextSrc(null);
    setFading(false);
  };

  const beginTransitionToIncoming = () => {
    clearFadeFrame();
    fadeFrameRef.current = window.requestAnimationFrame(() => {
      fadeFrameRef.current = window.requestAnimationFrame(() => {
        fadeFrameRef.current = null;
        if (nextRef.current !== targetRef.current) return;
        setFading(true);
      });
    });
  };

  useEffect(() => {
    const target = src.trim();
    targetRef.current = target;

    if (!target) {
      snapTo('');
      return undefined;
    }

    if (target === currentRef.current && !nextRef.current) {
      return undefined;
    }
    if (target === nextRef.current) {
      return undefined;
    }

    if (!animated || !currentRef.current) {
      snapTo(target);
      return undefined;
    }

    clearFadeFrame();
    nextRef.current = target;
    setFading(false);
    setNextSrc(target);
    return () => {
      clearFadeFrame();
    };
  }, [src, animated]);

  useLayoutEffect(() => {
    if (!nextSrc) return;
    const image = incomingRef.current;
    if (image && image.complete && image.naturalWidth > 0) {
      beginTransitionToIncoming();
    }
  }, [nextSrc]);

  useEffect(() => () => clearFadeFrame(), []);

  const onIncomingLoad = () => {
    if (nextRef.current !== targetRef.current) return;
    beginTransitionToIncoming();
  };

  const onIncomingError = () => {
    if (nextRef.current !== targetRef.current) return;
    snapTo(targetRef.current);
  };

  const onIncomingTransitionEnd = (event: TransitionEvent<HTMLImageElement>) => {
    const property = event.propertyName;
    if (property !== 'opacity' && property !== 'transform' && property !== 'clip-path') {
      return;
    }
    if (!fading || !nextRef.current || nextRef.current !== targetRef.current) return;
    snapTo(nextRef.current);
  };

  if (!currentSrc && !nextSrc) {
    return null;
  }

  const stackClassName = ['picture-transition-stack', className].filter(Boolean).join(' ');

  return (
    <div
      className={stackClassName}
      data-object-fit={objectFit}
      data-transition={pageTransition}
      data-transitioning={fading || nextSrc ? 'true' : 'false'}
      style={{ ['--picture-transition-ms' as string]: `${TRANSITION_MS}ms` }}
    >
      {currentSrc ? (
        <img
          className={`picture-transition-layer ${fading ? 'is-outgoing' : 'is-visible'}`}
          src={currentSrc}
          alt={alt}
          draggable={false}
        />
      ) : null}
      {nextSrc ? (
        <img
          ref={incomingRef}
          className={`picture-transition-layer ${fading ? 'is-incoming' : 'is-pending'}`}
          src={nextSrc}
          alt=""
          draggable={false}
          onLoad={onIncomingLoad}
          onError={onIncomingError}
          onTransitionEnd={onIncomingTransitionEnd}
        />
      ) : null}
    </div>
  );
}
