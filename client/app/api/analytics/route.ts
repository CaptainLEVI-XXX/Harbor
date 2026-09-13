import { loadBenchmark } from '@/lib/analytics/server';
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

/** Read-only, wallet-independent historical research. No arbitrary Graph proxy. */
export async function GET() {
  try {
    const data = await loadBenchmark();
    return Response.json(data, { headers: { 'Cache-Control': 'public, max-age=60', ETag: '"' + data.benchmarkId + '"' } });
  } catch (error) {
    console.error(error instanceof Error && ['Invalid analytics dataset', 'Analytics checksum mismatch'].includes(error.message) ? error.message : 'Analytics artifact unavailable');
    return Response.json({ error: 'Analytics data is temporarily unavailable.', code: error instanceof Error && error.message === 'Analytics checksum mismatch' ? 'INTEGRITY_MISMATCH' : error instanceof Error && error.message === 'Invalid analytics dataset' ? 'SCHEMA_MISMATCH' : 'ARTIFACT_UNAVAILABLE' }, { status: 503, headers: { 'Cache-Control': 'no-store' } });
  }
}
