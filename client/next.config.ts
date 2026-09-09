import type { NextConfig } from 'next';
import path from 'node:path';

const nextConfig: NextConfig = {
  // a stray package-lock.json in the home directory otherwise wins root detection
  turbopack: { root: path.join(__dirname) },
};

export default nextConfig;
