import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, it, expect, vi } from 'vitest';
import ReceiptList from '../ReceiptList';
import { RECEIPTS } from '@/lib/swap/fixtures';

describe('ReceiptList', () => {
  it('names the columns once, not once per row', () => {
    render(<ReceiptList receipts={RECEIPTS} selectedId={null} onSelect={() => {}} />);
    expect(screen.getAllByText('entitlement')).toHaveLength(1);
    expect(screen.getAllByText('mark')).toHaveLength(1);
  });

  it('puts entitlement and mark side by side so the gap between them is legible', () => {
    render(<ReceiptList receipts={RECEIPTS} selectedId={null} onSelect={() => {}} />);
    expect(screen.getByText('4.12')).toBeInTheDocument();
    expect(screen.getByText('3.9414')).toBeInTheDocument();
  });

  it('disables a finalized receipt and says why in place of a mark', () => {
    render(<ReceiptList receipts={RECEIPTS} selectedId={null} onSelect={() => {}} />);
    const row = screen.getByRole('button', { name: /18421/ });
    expect(row).toBeEnabled();
    const finalized = screen.getByRole('button', { name: /19003/ });
    expect(finalized).toBeDisabled();
    expect(finalized).toHaveTextContent('finalized');
  });

  it('selects a pending receipt', async () => {
    const onSelect = vi.fn();
    render(<ReceiptList receipts={RECEIPTS} selectedId={null} onSelect={onSelect} />);
    await userEvent.click(screen.getByRole('button', { name: /18421/ }));
    expect(onSelect).toHaveBeenCalledWith(18421);
  });

  it('never selects a finalized receipt', async () => {
    const onSelect = vi.fn();
    render(<ReceiptList receipts={RECEIPTS} selectedId={null} onSelect={onSelect} />);
    await userEvent.click(screen.getByRole('button', { name: /19003/ }));
    expect(onSelect).not.toHaveBeenCalled();
  });

  it('marks the selected row and only that row', () => {
    render(<ReceiptList receipts={RECEIPTS} selectedId={18422} onSelect={() => {}} />);
    expect(screen.getByRole('button', { name: /18422/ })).toHaveAttribute('aria-pressed', 'true');
    expect(screen.getByRole('button', { name: /18421/ })).toHaveAttribute('aria-pressed', 'false');
  });
});
