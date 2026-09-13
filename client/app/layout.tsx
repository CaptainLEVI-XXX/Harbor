import type { Metadata } from 'next';
import { Quicksand, Figtree, IBM_Plex_Mono } from 'next/font/google';
import { Providers } from '@/lib/wallet';
import './globals.css';

// Harbor Brand Guidelines §05 - Typography
const quicksand = Quicksand({ subsets: ['latin'], weight: ['500', '600', '700'], variable: '--font-display' });
const figtree = Figtree({ subsets: ['latin'], weight: ['400', '500', '600'], variable: '--font-body' });
const mono = IBM_Plex_Mono({ subsets: ['latin'], weight: ['400'], variable: '--font-mono' });

export const metadata: Metadata = {
  title: 'harbor',
  description: 'One pool, both sides of the trade.',
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body className={`${quicksand.variable} ${figtree.variable} ${mono.variable}`}>
        <Providers>{children}</Providers>
      </body>
    </html>
  );
}
