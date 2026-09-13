import HarborMark from './HarborMark';

/**
 * The coin beside a symbol. Assets wear their canonical marks - people
 * recognise an asset by its logo long before they read the ticker - while the
 * receipt, which has no issuer and is not fungible, wears a house glyph in a
 * deliberately non-coin shape.
 *
 * Drawn rather than fetched: the CSP allows no external images, and three
 * inline paths cost less than three network round trips.
 */

function Ethereum({ ink = '#FFF' }: { ink?: string }) {
  return <g fill={ink} fillRule="nonzero">
    <path fillOpacity=".602" d="M16.5 4v8.87l7.5 3.35z" />
    <path d="M16.5 4L9 16.22l7.5-3.35z" />
    <path fillOpacity=".602" d="M16.5 21.97V28L24 17.62z" />
    <path d="M16.5 28v-6.03L9 17.62z" />
    <path fillOpacity=".2" d="M16.5 20.57l7.5-4.35-7.5-3.35z" />
    <path fillOpacity=".602" d="M9 16.22l7.5 4.35v-7.7z" />
  </g>;
}

const MARKS: Record<string, React.ReactNode> = {
  ETH: <>
    <circle cx="16" cy="16" r="16" fill="#627EEA" />
    <Ethereum />
  </>,
  // Lido's droplet: an upper diamond over a round bowl, folded at the waist
  wstETH: <>
    <circle cx="16" cy="16" r="16" fill="#F2F6F9" />
    <circle cx="16" cy="19.6" r="8" fill="#00A3FF" />
    <path d="M16 11.6A8 8 0 0116 27.6z" fill="#7FD4FF" />
    <path d="M16 3.6L9.4 15.2 16 19l6.6-3.8z" fill="#00A3FF" />
    <path d="M16 3.6l6.6 11.6L16 19z" fill="#7FD4FF" />
    <path d="M9.4 15.2L16 19l6.6-3.8L16 22.4z" fill="#D7F0FF" />
  </>,
  // wrapped ether: a white coin with its pink edge showing, the ticker struck on the face
  WETH: <>
    <circle cx="14.2" cy="16" r="15.4" fill="#EC1C79" />
    <circle cx="17" cy="16" r="14.2" fill="#FFF" stroke="#16121C" strokeWidth="1.7" />
    <text x="17" y="19.1" textAnchor="middle" fontFamily="Arial Black, Arial, sans-serif" fontWeight="900" fontSize="8.6" letterSpacing="-.3" fill="#16121C">WETH</text>
  </>,
  // not a coin: a claim ticket, torn along the bottom
  receipt: <>
    <circle cx="16" cy="16" r="16" fill="#EDE6F8" />
    <path d="M10.5 8.5h11v15l-2.75-2-2.75 2-2.75-2-2.75 2z" fill="#6A3FD1" />
    <path d="M13.2 13h5.6M13.2 16.6h5.6" stroke="#EDE6F8" strokeWidth="1.7" strokeLinecap="round" />
  </>,
};

/** Hoodi is an Ethereum testnet, so the network wears Ethereum's own mark. */
function ChainMark() {
  return <svg viewBox="0 0 32 32" className="chainmark" aria-hidden="true">
    <circle cx="16" cy="16" r="16" fill="#ECEFF3" />
    <Ethereum ink="#3C3C3B" />
  </svg>;
}

// the issuer wears the droplet its staked token carries
MARKS.lido = MARKS.wstETH;

export default function TokenMark({ symbol, chain = false }: { symbol: string; chain?: boolean }) {
  // the vault share wears the vault's own mark: the harbor bowl holding WETH
  if (symbol === 'hWETH') return <span className="tmark hweth"><HarborMark face="weth" still /></span>;
  const mark = MARKS[symbol];
  if (!mark) return null;
  return <span className="tmark">
    <svg viewBox="0 0 32 32" aria-hidden="true">{mark}</svg>
    {chain && <ChainMark />}
  </span>;
}
