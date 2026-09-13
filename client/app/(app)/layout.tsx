'use client';

import { usePathname } from 'next/navigation';
import Ground from '@/components/Ground';
import Nav from '@/components/Nav';
import { useConnect } from '@/lib/wallet';
import { DisplayPriceProvider } from '@/lib/harbor/DisplayPriceProvider';

/** Route -> the nav destination it lights up. The landing page lights none. */
const ACTIVE: Record<string, string> = { '/swap': 'trade', '/earn': 'earn', '/testnet': 'testnet', '/analytics': 'analytics' };

/** Routes that scroll. Every other route stays exactly one viewport. */
const SCROLLS = new Set(['/earn', '/swap', '/testnet', '/analytics']);

/**
 * The shell every route shares. Ground renders here, once, so the canvas is
 * never torn down on navigation - cells popped on one page are still popped
 * on the next. Coins are landing-only and live in that page, not here.
 *
 * `.groundbox` is unconditional. Rendering it only on scrolling routes would
 * change the element type at that position and remount Ground, which is the
 * one thing this layout exists to prevent.
 */
export default function AppLayout({ children }: { children: React.ReactNode }) {
  const { label, onConnect } = useConnect();
  const pathname = usePathname();
  const active = ACTIVE[pathname];
  const scrolls = SCROLLS.has(pathname);

  return (
    <DisplayPriceProvider><main className={scrolls ? 'stage stage--scroll' : 'stage'}>
      <div className="groundbox">
        <Ground />
      </div>
      <div className="fg">
        <Nav onConnect={onConnect} connectLabel={label} active={active} />
        {children}
      </div>
    </main></DisplayPriceProvider>
  );
}
