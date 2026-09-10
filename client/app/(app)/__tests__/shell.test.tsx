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

describe('the scrolling route', () => {
  it('wraps Ground in a box on every route, so navigation never remounts it', () => {
    const layout = readFileSync(join(process.cwd(), 'app/(app)/layout.tsx'), 'utf8');
    expect(layout).toContain('className="groundbox"');
    // one unconditional wrapper - a conditional one would change element type
    // between routes and remount the canvas, losing every popped cell
    expect(layout).not.toMatch(/\?\s*<div className="groundbox">/);
  });

  it('releases the viewport lock only on /earn', () => {
    const layout = readFileSync(join(process.cwd(), 'app/(app)/layout.tsx'), 'utf8');
    expect(layout).toContain("'/earn'");
    expect(layout).toContain('stage--scroll');

    const css = readFileSync(join(process.cwd(), 'app/globals.css'), 'utf8');
    // the lock lives on .stage now, not on html/body
    expect(css).not.toMatch(/html,\s*body\s*\{[^}]*overflow:\s*hidden/);
    expect(css).toMatch(/\.stage\s*\{[^}]*overflow:\s*hidden/);
    expect(css).toContain('.stage--scroll');
    // the ground stays put while content scrolls over it
    expect(css).toMatch(/\.stage--scroll \.groundbox\s*\{[^}]*position:\s*fixed/);
  });

  it('points the Earn nav link at the route', () => {
    const { getByText } = render(<Nav onConnect={() => {}} connectLabel="Connect wallet" active="Earn" />);
    const link = getByText('Earn');
    expect(link).toHaveAttribute('href', '/earn');
    expect(link).toHaveAttribute('aria-current', 'page');
  });
});
