import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, it, expect } from 'vitest';

describe('useConnect', () => {
  it('reports whether a wallet is connected, not only a label', () => {
    const source = readFileSync(join(process.cwd(), 'components/PrivyProvider.tsx'), 'utf8');
    expect(source).toContain('connected: boolean');
    expect(source).toContain('connected: false');
  });
});
