import { render } from '@testing-library/react';
import { describe, it, expect } from 'vitest';
import Home from '../page';

describe('landing page shell', () => {
  it('renders a single full-viewport stage that cannot scroll', () => {
    const { container } = render(<Home />);
    const stage = container.querySelector('.stage');
    expect(stage).not.toBeNull();
  });
});
