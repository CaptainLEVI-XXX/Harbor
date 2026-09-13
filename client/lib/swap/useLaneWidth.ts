'use client';

import { useEffect, useLayoutEffect, useState } from 'react';

const useIsomorphic = typeof window === 'undefined' ? useEffect : useLayoutEffect;

/**
 * The width of the nav bar - the one "lane" the page already has. The swap
 * deck matches it so the card and the bar above it read as a single column
 * rather than two unrelated widths stacked on a patterned ground.
 *
 * Measured rather than derived: the bar sizes itself to its own labels at a
 * type scale that tracks the viewport, and those labels change. A number
 * copied out of the stylesheet would be wrong the first time either moves.
 */
type Lane = { width: number; left: number };

/** the widths the deck will actually honour; outside them there is no lane */
const MIN = 360;
const MAX = 860;

export function useLaneWidth(): Lane {
  const [lane, setLane] = useState<Lane>({ width: 0, left: 0 });
  useIsomorphic(() => {
    const bar = document.querySelector('.navlinks');
    if (!bar) return;
    const read = () => {
      const r = bar.getBoundingClientRect();
      const stage = bar.closest('.stage')?.getBoundingClientRect();
      const width = Math.round(r.width);
      // The bar centres itself in the room the wordmark and the connect button
      // leave it, which is not the middle of the page. Matching its width but
      // not its edge would put the card 20-odd pixels off the lane it is meant
      // to share, so the left edge is measured too - and dropped entirely at
      // widths where the deck cannot take the bar's size anyway.
      const left = stage && width >= MIN && width <= MAX
        ? Math.round(r.left - stage.left)
        : 0;
      setLane(prev => (prev.width === width && prev.left === left ? prev : { width, left }));
    };
    read();
    const ro = new ResizeObserver(read);
    ro.observe(bar);
    const stage = bar.closest('.stage');
    if (stage) ro.observe(stage);
    return () => ro.disconnect();
  }, []);
  return lane;
}
