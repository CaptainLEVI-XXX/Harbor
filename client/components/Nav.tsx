import Link from 'next/link';
import { DESIGN } from '@/lib/design';
import HarborMark from './HarborMark';
import WalletButton from './WalletButton';

type Props = { onConnect: () => void; connectLabel: string; active?: string };

/**
 * Items that are not routes are spans, not dead links: an anchor to "#" is
 * focusable, clickable and lies about arriving somewhere. portfolio and docs
 * are announced as coming; analytics is named before it is a route.
 * trade keeps the /swap address so existing links still land.
 */
const HREF: Record<string, string> = { trade: '/swap', earn: '/earn', testnet: '/testnet' };
const SOON = new Set(['portfolio', 'docs']);

export default function Nav({ onConnect, connectLabel, active }: Props) {
  return (
    <nav className="nav">
      {/* the wordmark: the symbol is its "o" */}
      <Link href="/" className="mark" aria-label="harbor">
        harb<HarborMark />r<sup>beta</sup>
      </Link>

      <div className="navlinks">
        {DESIGN.copy.nav.map(item => HREF[item] ? (
          <Link
            key={item}
            href={HREF[item]}
            aria-current={item === active ? 'page' : undefined}
          >
            {item}
          </Link>
        ) : SOON.has(item) ? (
          <span key={item} className="soonlink" aria-disabled="true">
            {item}<em className="soon">soon</em>
          </span>
        ) : (
          <span key={item} className="navlabel" aria-disabled="true">{item}</span>
        ))}
      </div>

      <WalletButton onConnect={onConnect} connectLabel={connectLabel} />
    </nav>
  );
}
