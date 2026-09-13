import { render } from '@testing-library/react';
import { describe, it, expect, vi, beforeAll } from 'vitest';
import FloatingCoins from '../FloatingCoins';
import HarborMark from '../HarborMark';

beforeAll(() => {
  Object.defineProperty(window, 'matchMedia', {
    writable: true,
    value: vi.fn().mockImplementation((q: string) => ({
      matches: q.includes('prefers-reduced-motion'),
      media: q, addEventListener: vi.fn(), removeEventListener: vi.fn(),
      addListener: vi.fn(), removeListener: vi.fn(), onchange: null, dispatchEvent: vi.fn(),
    })),
  });
});

describe('reduced motion', () => {
  it('leaves coins untransformed when the user asks for reduced motion', async () => {
    const { container } = render(<FloatingCoins />);
    await new Promise(r => setTimeout(r, 50));
    const wrappers = container.querySelectorAll('.layer > div');
    expect(wrappers.length).toBeGreaterThan(0);
    wrappers.forEach(w => {
      expect((w as HTMLElement).style.transform).toBe('');
    });
  });
});

describe('the Harbor mark under reduced motion', () => {
  it('shows the settled pose instead of the rolling coin', () => {
    const { container } = render(<HarborMark />);
    const [bowl, coin] = container.querySelectorAll('svg > g');
    expect(bowl.getAttribute('transform')).toBe('rotate(0.000)');
    expect(coin.getAttribute('transform')).toBe('translate(0.000 11.800)');
  });
});
