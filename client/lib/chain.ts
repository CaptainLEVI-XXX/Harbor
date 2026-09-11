import { createPublicClient, http, type Address } from 'viem';
import { hoodi, sepolia } from 'viem/chains';

type Tokens = Record<'WETH' | 'wstETH', Address>;

const SEPOLIA_TOKENS: Tokens = {
  WETH: '0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14',
  wstETH: '0xB82381A3fBD3FaFA77B3a7bE693342618240067b',
};

function hoodiTokens(): Tokens {
  const weth = process.env.NEXT_PUBLIC_HOODI_WETH;
  // Hoodi has no canonical WETH9 - the Harbor deployment brings its own
  if (!weth) throw new Error('NEXT_PUBLIC_HOODI_WETH must be set when NEXT_PUBLIC_CHAIN=hoodi.');
  return { WETH: weth as Address, wstETH: '0x7E99eE3C66636DE415D2d7C880938F2f40f94De4' };
}

const onHoodi = process.env.NEXT_PUBLIC_CHAIN === 'hoodi';

export const chain = onHoodi ? hoodi : sepolia;

/** Privy sponsors gas on Sepolia. Hoodi is not on its list, so users pay there. */
export const sponsored = !onHoodi;

export const TOKENS: Tokens = onHoodi ? hoodiTokens() : SEPOLIA_TOKENS;

export const publicClient = createPublicClient({ chain, transport: http() });
