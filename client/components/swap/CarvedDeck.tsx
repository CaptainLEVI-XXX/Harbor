'use client';

import {
  useEffect, useId, useLayoutEffect, useRef, useState,
  type CSSProperties, type ReactNode,
} from 'react';
import {
  aroundPath, carvePath, deckGeometry, notchFor, TILE_RADIUS,
  type DeckGeometry, type Notch,
} from '@/lib/swap/carve';

/** layout effects run before paint on the client; on the server there is none */
const useIsomorphic = typeof window === 'undefined' ? useEffect : useLayoutEffect;

/** the element's border box, tracked. Nothing here feeds back into layout. */
function useBox(ref: React.RefObject<HTMLElement | null>, also?: 'stage') {
  const [box, setBox] = useState({ w: 0, h: 0 });
  useIsomorphic(() => {
    const el = ref.current;
    if (!el) return;
    const target = also === 'stage'
      ? (el.closest('.stage') as HTMLElement | null) ?? el
      : el;
    const read = () => setBox(prev => {
      const w = target.clientWidth, h = target.clientHeight;
      return prev.w === w && prev.h === h ? prev : { w, h };
    });
    read();
    const ro = new ResizeObserver(read);
    ro.observe(target);
    return () => ro.disconnect();
  }, [ref, also]);
  return box;
}

/**
 * The window's own height. NOT the stage's: the swap route scrolls, so the
 * stage grows with its content and would report the document height instead.
 * This is the same measure the stylesheet's vh clamps are scaling against.
 */
function useViewportHeight() {
  const [vh, setVh] = useState(0);
  useIsomorphic(() => {
    const read = () => setVh(window.innerHeight);
    read();
    window.addEventListener('resize', read);
    return () => window.removeEventListener('resize', read);
  }, []);
  return vh;
}

type PanelProps = { notch: Notch; width: number; geo: DeckGeometry; children: ReactNode };

/**
 * One panel of the deck. The face is a real translucent surface clipped to the
 * silhouette, so the lattice shows through it AND through the notch; the SVG
 * beside it carries only the trim - the shadow outside the shape, the luminous
 * edge inside it. Decoration never sits in the same box as the inputs.
 *
 * Before the first measurement the panel falls back to a plain rounded glass
 * rectangle, so the server's HTML is never a bare, unstyled block.
 */
function GlassPanel({ notch, width, geo, children }: PanelProps) {
  const ref = useRef<HTMLDivElement>(null);
  const { h } = useBox(ref);
  const raw = useId();
  const uid = raw.replace(/[^a-zA-Z0-9]/g, '');

  const carve = notchFor(geo, width, h, notch);
  const ready = width > 0 && h > 0;
  const d = ready ? carvePath(carve) : '';

  return (
    <div className="gpanel" ref={ref} data-carved={ready ? '' : undefined}>
      {ready && (
        <>
          <div className="gface" style={{ clipPath: `path('${d}')` }} />
          <svg className="gart" viewBox={`0 0 ${width} ${h}`} width={width} height={h} aria-hidden="true">
            <defs>
              <linearGradient id={`e${uid}`} x1="0" y1="0" x2="0" y2="1">
                <stop offset="0" stopColor="#fff" stopOpacity=".96" />
                <stop offset=".38" stopColor="#fff" stopOpacity=".60" />
                <stop offset="1" stopColor="#fff" stopOpacity=".34" />
              </linearGradient>
              <filter id={`s${uid}`} x="-30%" y="-30%" width="160%" height="160%">
                <feGaussianBlur stdDeviation="15" />
              </filter>
              <filter id={`g${uid}`} x="-20%" y="-20%" width="140%" height="140%">
                <feGaussianBlur stdDeviation="2.6" />
              </filter>
              <clipPath id={`in${uid}`}><path d={d} /></clipPath>
              <clipPath id={`out${uid}`}>
                <path d={aroundPath(carve)} clipRule="evenodd" />
              </clipPath>
            </defs>

            {/* separation: plum, soft, and only ever outside the silhouette */}
            <g clipPath={`url(#out${uid})`}>
              <path
                d={d} transform="translate(0 11)" fill="#4A2F6B" opacity=".17"
                filter={`url(#s${uid})`}
              />
            </g>

            {/* thickness, then the hairline - both follow the notch contour */}
            <g clipPath={`url(#in${uid})`}>
              <path
                d={d} fill="none" stroke="rgba(255,255,255,.34)" strokeWidth="7"
                filter={`url(#g${uid})`}
              />
              <path d={d} fill="none" stroke={`url(#e${uid})`} strokeWidth="2" />
            </g>
          </svg>
        </>
      )}
      <div className="gbody">{children}</div>
    </div>
  );
}

/** two arrows, drawn rather than typed: at this size a glyph goes soft */
function Reverse() {
  return (
    <svg className="pivoticon" viewBox="0 0 24 24" fill="none" aria-hidden="true">
      <path
        d="M8.6 19.2V4.9m0 0L4.9 8.7m3.7-3.8 3.7 3.8M15.4 4.8v14.3m0 0 3.7-3.8m-3.7 3.8-3.7-3.8"
        stroke="#4A2F6B" strokeWidth="2.1" strokeLinecap="round" strokeLinejoin="round"
      />
    </svg>
  );
}

/** one arrow, for a flow that only goes one way */
function Arrow({ up }: { up: boolean }) {
  return (
    <svg className="pivoticon" viewBox="0 0 24 24" fill="none" aria-hidden="true" style={up ? { transform: 'rotate(180deg)' } : undefined}>
      <path d="M12 4.8v14.4m0 0-5-5m5 5 5-5" stroke="#4A2F6B" strokeWidth="2.1" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

type Props = {
  pay: ReactNode;
  receive: ReactNode;
  onReverse?: () => void;
  reverseLabel?: string;
  /** which way a one-way marker points: value flows from top to bottom, or back up */
  flow?: 'down' | 'up';
};

/**
 * Pay and Receive, with the direction control sitting in the channel between
 * them. The control's side is one lattice cell and carries the lattice's own
 * corner, so the pair reads as a tile prised out of the two sheets of glass.
 *
 * Without `onReverse` the tile is a marker, not a control: the flow has one
 * direction, so it says which way and offers nothing to press.
 */
export default function CarvedDeck({ pay, receive, onReverse, reverseLabel = 'Reverse direction', flow = 'down' }: Props) {
  const ref = useRef<HTMLDivElement>(null);
  const own = useBox(ref);
  const stage = useBox(ref, 'stage');
  const geo = deckGeometry(stage.w, own.w, useViewportHeight());

  const vars = {
    '--tile': `${geo.tile}px`,
    '--pgap': `${geo.gap}px`,
    '--pr': `${geo.radius}px`,
    '--tile-r': `${geo.tile * TILE_RADIUS}px`,
  } as CSSProperties;

  return (
    <div className="deck" ref={ref} style={vars}>
      <GlassPanel notch="bottom" width={own.w} geo={geo}>{pay}</GlassPanel>
      <div className="pivotslot">
        {onReverse ? (
          <button type="button" className="pivot" aria-label={reverseLabel} onClick={onReverse}>
            <Reverse />
          </button>
        ) : (
          <span className="pivot" aria-hidden="true"><Arrow up={flow === 'up'} /></span>
        )}
      </div>
      <GlassPanel notch="top" width={own.w} geo={geo}>{receive}</GlassPanel>
    </div>
  );
}
