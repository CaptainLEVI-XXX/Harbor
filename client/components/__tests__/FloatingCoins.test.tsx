import { render } from '@testing-library/react';
import { describe, it, expect } from 'vitest';
import FloatingCoins from '../FloatingCoins';
import { DESIGN } from '@/lib/design';

describe('FloatingCoins', () => {
  it('renders one coin per spec entry', () => {
    const { container } = render(<FloatingCoins />);
    expect(container.querySelectorAll('svg')).toHaveLength(DESIGN.coins.length);
  });

  it('gives every coin a detached cast shadow', () => {
    const { container } = render(<FloatingCoins />);
    const shadows = container.querySelectorAll('ellipse[data-role="shadow"]');
    expect(shadows).toHaveLength(DESIGN.coins.length);
    shadows.forEach(s => {
      expect(Number(s.getAttribute('cy'))).toBeGreaterThan(180);
      expect(Number(s.getAttribute('rx'))).toBe(66);
      expect(Number(s.getAttribute('ry'))).toBe(9);
      expect(s.getAttribute('opacity')).toBe('.22');
    });
  });
});
