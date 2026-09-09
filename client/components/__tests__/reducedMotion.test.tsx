import { render } from '@testing-library/react';
import { describe, it, expect, vi, beforeAll } from 'vitest';
import FloatingCoins from '../FloatingCoins';

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
