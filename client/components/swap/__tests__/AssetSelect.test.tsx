import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, it, expect, vi, beforeAll } from 'vitest';
import AssetSelect from '../AssetSelect';
import { ASSETS } from '@/lib/swap/fixtures';

const options = [ASSETS.wstETH, ASSETS.WETH];

beforeAll(() => {
  // Radix measures its popper; jsdom implements neither of these.
  window.HTMLElement.prototype.scrollIntoView = vi.fn();
  window.HTMLElement.prototype.hasPointerCapture = vi.fn(() => false);
  window.HTMLElement.prototype.releasePointerCapture = vi.fn();
});

describe('AssetSelect', () => {
  it('shows the chosen symbol', () => {
    render(<AssetSelect label="Pay asset" value="wstETH" options={options} onChange={() => {}} />);
    expect(screen.getByRole('combobox', { name: 'Pay asset' })).toHaveTextContent('wstETH');
  });

  it('is a real control even before there is a second pair', async () => {
    const onChange = vi.fn();
    render(<AssetSelect label="Pay asset" value="wstETH" options={[ASSETS.wstETH]} onChange={onChange} />);
    await userEvent.click(screen.getByRole('combobox', { name: 'Pay asset' }));
    expect(await screen.findByRole('option', { name: /wstETH/ })).toBeInTheDocument();
  });

  it('reports the symbol that was picked', async () => {
    const onChange = vi.fn();
    render(<AssetSelect label="Pay asset" value="wstETH" options={options} onChange={onChange} />);
    await userEvent.click(screen.getByRole('combobox', { name: 'Pay asset' }));
    await userEvent.click(await screen.findByRole('option', { name: /WETH/ }));
    expect(onChange).toHaveBeenCalledWith('WETH');
  });
});
