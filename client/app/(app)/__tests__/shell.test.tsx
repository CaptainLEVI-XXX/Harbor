import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { render, screen } from '@testing-library/react';
import { describe, it, expect } from 'vitest';
import Nav from '@/components/Nav';

describe('Nav active state', () => {
  it('marks nothing current when no active route is given', () => {
    const { container } = render(<Nav onConnect={() => {}} connectLabel="Connect wallet" />);
    expect(container.querySelector('[aria-current]')).toBeNull();
  });

  it('marks only the active route', () => {
    render(<Nav onConnect={() => {}} connectLabel="Connect wallet" active="Swap" />);
    expect(screen.getByRole('link', { name: 'Swap' })).toHaveAttribute('aria-current', 'page');
    expect(screen.getByRole('link', { name: 'Earn' })).not.toHaveAttribute('aria-current');
  });

  it('links each destination to its route', () => {
    render(<Nav onConnect={() => {}} connectLabel="Connect wallet" active="Swap" />);
    expect(screen.getByRole('link', { name: 'Swap' })).toHaveAttribute('href', '/swap');
  });
});

describe('the shared shell', () => {
  it('keeps Ground out of the pages, so navigation never remounts the canvas', () => {
    const layout = readFileSync(join(process.cwd(), 'app/(app)/layout.tsx'), 'utf8');
    expect(layout).toContain('<Ground />');

    for (const page of ['app/(app)/page.tsx', 'app/(app)/swap/page.tsx']) {
      const source = readFileSync(join(process.cwd(), page), 'utf8');
      expect(source, page).not.toContain('Ground');
    }
  });

  it('keeps the coins on the landing page only', () => {
    const landing = readFileSync(join(process.cwd(), 'app/(app)/page.tsx'), 'utf8');
    const swap = readFileSync(join(process.cwd(), 'app/(app)/swap/page.tsx'), 'utf8');
    const layout = readFileSync(join(process.cwd(), 'app/(app)/layout.tsx'), 'utf8');
    expect(landing).toContain('FloatingCoins');
    expect(swap).not.toContain('FloatingCoins');
    expect(layout).not.toContain('FloatingCoins');
  });
});
