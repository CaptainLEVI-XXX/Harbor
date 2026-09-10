'use client';

import { usePathname } from 'next/navigation';
import Ground from '@/components/Ground';
import Nav from '@/components/Nav';
import { useConnect } from '@/components/PrivyProvider';

/** Route -> the nav destination it lights up. The landing page lights none. */
const ACTIVE: Record<string, string> = { '/swap': 'Swap' };

/**
 * The shell every route shares. Ground renders here, once, so the canvas is
 * never torn down on navigation - cells popped on one page are still popped
 * on the next. Coins are landing-only and live in that page, not here.
 */
export default function AppLayout({ children }: { children: React.ReactNode }) {
  const { label, onConnect } = useConnect();
  const active = ACTIVE[usePathname()];

  return (
    <main className="stage">
      <Ground />
      <div className="fg">
        <Nav onConnect={onConnect} connectLabel={label} active={active} />
        {children}
      </div>
    </main>
  );
}
