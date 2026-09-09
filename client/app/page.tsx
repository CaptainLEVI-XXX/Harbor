'use client';

import Ground from '@/components/Ground';
import FloatingCoins from '@/components/FloatingCoins';
import Nav from '@/components/Nav';
import Hero from '@/components/Hero';
import { useConnect } from '@/components/PrivyProvider';

export default function Home() {
  const { label, onConnect } = useConnect();

  return (
    <main className="stage">
      <Ground />
      <FloatingCoins />
      <div className="fg">
        <Nav onConnect={onConnect} connectLabel={label} />
        <Hero />
      </div>
    </main>
  );
}
