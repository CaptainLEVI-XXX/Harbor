import { render } from '@testing-library/react';
import { describe, it, expect, vi, beforeAll } from 'vitest';
import Ground from '../Ground';

beforeAll(() => {
  HTMLCanvasElement.prototype.getContext = vi.fn(() => ({
    setTransform: vi.fn(), clearRect: vi.fn(), fillRect: vi.fn(), rect: vi.fn(),
    createRadialGradient: () => ({ addColorStop: vi.fn() }),
    createLinearGradient: () => ({ addColorStop: vi.fn() }),
    beginPath: vi.fn(), moveTo: vi.fn(), arcTo: vi.fn(), closePath: vi.fn(),
    save: vi.fn(), restore: vi.fn(), clip: vi.fn(),
    fillStyle: '', globalAlpha: 1,
  })) as unknown as typeof HTMLCanvasElement.prototype.getContext;
});

describe('Ground', () => {
  it('renders a base canvas and a dent canvas', () => {
    const { container } = render(<Ground />);
    expect(container.querySelectorAll('canvas')).toHaveLength(2);
  });
  it('renders a layer for burst coins', () => {
    const { container } = render(<Ground />);
    expect(container.querySelector('[data-testid="burst-layer"]')).not.toBeNull();
  });
});
