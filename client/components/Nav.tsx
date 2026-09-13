import Link from 'next/link';
import { DESIGN } from '@/lib/design';
import HarborMark from './HarborMark';
import WalletButton from './WalletButton';

type Props = { onConnect: () => void; connectLabel: string; active?: string };

/**
 * Portfolio, Analytics and Docs are not routes yet - see the spec's
 * out-of-scope list. They are named rather than hidden, because a nav that
 * grows items later teaches the shape twice; but they are spans, not dead
 * links: an anchor to "#" is focusable, clickable and lies about arriving
 * somewhere. The lavender curtain and the word say the rest.
 */
const HREF: Record<string, string> = { Swap: '/swap', Earn: '/earn', Testnet: '/testnet' };

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
        ) : (
          <span key={item} className="soonlink" aria-disabled="true">
            {item}<em className="soon">soon</em>
          </span>
        ))}
      </div>

      <WalletButton onConnect={onConnect} connectLabel={connectLabel} />
    </nav>
  );
}
