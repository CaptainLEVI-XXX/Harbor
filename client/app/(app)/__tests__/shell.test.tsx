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
