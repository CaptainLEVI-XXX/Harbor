import Link from 'next/link';
import { DESIGN } from '@/lib/design';
import HarborMark from './HarborMark';

type Props = { onConnect: () => void; connectLabel: string; active?: string };

/**
 * Portfolio, Analytics and Docs stay dead links rather than routes that 404 -
 * see the spec's out-of-scope list.
 */
const HREF: Record<string, string> = { Swap: '/swap', Earn: '/earn' };

export default function Nav({ onConnect, connectLabel, active }: Props) {
  return (
    <nav className="nav">
      <Link href="/" className="mark">
        <HarborMark />
        Harbor<sup>beta</sup>
      </Link>

      <div className="navlinks">
        {DESIGN.copy.nav.map(item => (
          <Link
            key={item}
            href={HREF[item] ?? '#'}
            aria-current={item === active ? 'page' : undefined}
          >
            {item}
          </Link>
        ))}
      </div>

      <button type="button" className="connect" onClick={onConnect}>
        {connectLabel}
      </button>
    </nav>
  );
}
