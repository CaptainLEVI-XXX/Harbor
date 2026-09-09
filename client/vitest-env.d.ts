// Registers @testing-library/jest-dom's matchers with vitest's Assertion type.
// Needed because vitest.setup.ts is excluded from the Next build typecheck
// (it pulls in vitest's bundled vite, which clashes with Next 16's rolldown-vite).
import 'vitest';
import type { TestingLibraryMatchers } from '@testing-library/jest-dom/matchers';

declare module 'vitest' {
  // eslint-disable-next-line @typescript-eslint/no-empty-object-type
  interface Assertion<T = unknown> extends TestingLibraryMatchers<T, void> {}
  // eslint-disable-next-line @typescript-eslint/no-empty-object-type
  interface AsymmetricMatchersContaining extends TestingLibraryMatchers<unknown, void> {}
}
