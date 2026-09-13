import { afterEach, describe, expect, it, vi } from 'vitest';
import { GET } from '@/app/api/harbor/route';
import { GRAPH_DEPLOYMENT, HARBOR } from '../config';
afterEach(() => vi.unstubAllGlobals());
describe('Graph read boundary', () => {
  it('pins page data to the provider block and rejects incomplete projections', async () => {
    const _meta = { deployment: GRAPH_DEPLOYMENT, hasIndexingErrors: false, block: { number: 42, hash: `0x${'11'.repeat(32)}` } };
    const fetch = vi.fn().mockResolvedValueOnce(Response.json({ data: { _meta } })).mockResolvedValueOnce(Response.json({ data: { _meta, pool: { book: HARBOR.book, chainId: '560048', complete: false } } }));
    vi.stubGlobal('fetch', fetch);
    const result = await GET(new Request('http://localhost/api/harbor'));
    expect(result.status).toBe(503);
    expect(JSON.parse(fetch.mock.calls[1][1].body).variables.block).toEqual({ hash: _meta.block.hash });
  });
  it('rejects invalid wallet filters without contacting the provider', async () => {
    const fetch = vi.fn(); vi.stubGlobal('fetch', fetch);
    expect((await GET(new Request('http://localhost/api/harbor?owner=not-an-address'))).status).toBe(400);
    expect(fetch).not.toHaveBeenCalled();
  });
});
