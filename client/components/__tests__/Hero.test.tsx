import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, it, expect, vi } from 'vitest';
import Nav from '../Nav';
import Hero from '../Hero';
import { DESIGN } from '@/lib/design';

describe('Nav', () => {
  it('renders the wordmark, all five destinations and the connect button', () => {
    render(<Nav onConnect={() => {}} connectLabel={DESIGN.copy.connect} />);
    expect(screen.getByText('Harbor')).toBeInTheDocument();
    for (const item of DESIGN.copy.nav) expect(screen.getByText(item)).toBeInTheDocument();
    expect(screen.getByRole('button', { name: DESIGN.copy.connect })).toBeInTheDocument();
  });

  it('marks no destination as active - nothing is selected on the landing page', () => {
    const { container } = render(<Nav onConnect={() => {}} connectLabel="Connect wallet" />);
    expect(container.querySelector('[aria-current]')).toBeNull();
  });

  it('calls onConnect when the button is pressed', async () => {
    const onConnect = vi.fn();
    render(<Nav onConnect={onConnect} connectLabel="Connect wallet" />);
    await userEvent.click(screen.getByRole('button', { name: 'Connect wallet' }));
    expect(onConnect).toHaveBeenCalledOnce();
  });
});

describe('Hero', () => {
  it('renders the spec copy verbatim and carries no call to action', () => {
    render(<Hero />);
    expect(screen.getByRole('heading', { level: 1 })).toHaveTextContent(DESIGN.copy.headline);
    expect(screen.getByText(DESIGN.copy.subcopy)).toBeInTheDocument();
    expect(screen.getByText(DESIGN.copy.availability)).toBeInTheDocument();
    expect(screen.queryByRole('button')).toBeNull();
  });
});
