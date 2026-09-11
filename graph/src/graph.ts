import { AnalyticsError, requireValue } from "./types.js";
import type { GraphHead, NumberGraphHead } from "./types.js";

/** Bound decoded response size for both Graph and read-only RPC transports. */
export async function jsonBody(response: Response): Promise<Record<string, unknown>> {
  const reader = response.body?.getReader();
  requireValue(reader, "EMPTY_RESPONSE");
  const chunks: Uint8Array[] = [];
  let length = 0;
  try {
    while (true) {
      const chunk = await reader.read();
      if (chunk.done) break;
      length += chunk.value.length;
      requireValue(length <= 2_000_000, "RESPONSE_TOO_LARGE");
      chunks.push(chunk.value);
    }
  } finally { await reader.cancel(); }
  return object(JSON.parse(Buffer.concat(chunks).toString("utf8")));
}

export type GraphRequest = (query: string, variables?: Record<string, unknown>) => Promise<unknown>;

/** Bounded read-only Graph transport. Never surface provider bodies or URLs as errors. */
export function graphClient(endpoint: string, apiKey: string | undefined, fetcher: typeof fetch = fetch): GraphRequest {
  requireValue(typeof apiKey === "string" && apiKey.trim().length > 0, "MISSING_GRAPH_API_KEY");
  requireValue(/^https:\/\/gateway\.thegraph\.com\/api\/subgraphs\/id\/[1-9A-HJ-NP-Za-km-z]{40,60}$/.test(endpoint), "UNAPPROVED_ENDPOINT");
  return async (query, variables = {}) => {
    try {
      const response = await fetcher(endpoint, {
        method: "POST",
        redirect: "error",
        headers: { "Content-Type": "application/json", Authorization: `Bearer ${apiKey}` },
        body: JSON.stringify({ query, variables }),
        signal: AbortSignal.timeout(15_000),
      });
      requireValue(response.ok, response.status === 401 || response.status === 403 ? "PROVIDER_AUTH" : "PROVIDER_HTTP");
      const payload = await jsonBody(response);
      // A GraphQL error can accompany HTTP 200 or partial data. Neither is success.
      if (payload.errors !== undefined) {
        requireValue(Array.isArray(payload.errors), "GRAPHQL_ERROR");
        if (payload.errors.length > 0) {
          // Classify for operations without reflecting provider text or credentials.
          const message = payload.errors.map(error => typeof error?.message === "string" ? error.message : "").join(" ");
          const code = /auth|api.?key|unauthorized/i.test(message) ? "PROVIDER_AUTH"
            : /payment|billing|spend|quota|rate.?limit/i.test(message) ? "PROVIDER_ALLOWANCE"
            : /cannot query field|unknown (type|argument)|variable .*type/i.test(message) ? "SCHEMA_QUERY_MISMATCH"
            : /indexer|deployment|subgraph.*(found|available)/i.test(message) ? "SOURCE_UNAVAILABLE"
            : "GRAPHQL_ERROR";
          throw new AnalyticsError(code);
        }
      }
      requireValue(payload.data !== null && payload.data !== undefined, "MISSING_DATA");
      return payload.data;
    } catch (error) {
      if (error instanceof AnalyticsError) throw error;
      throw new AnalyticsError("PROVIDER_REQUEST_FAILED");
    }
  };
}

export function object(value: unknown): Record<string, unknown> {
  requireValue(typeof value === "object" && value !== null && !Array.isArray(value), "INVALID_RESPONSE");
  return value as Record<string, unknown>;
}

export function headOf(data: unknown): GraphHead {
  const head = numberHeadOf(data);
  requireValue(head.block.hash !== null, "MISSING_BLOCK_HASH");
  return { deployment: head.deployment, block: { number: head.block.number, hash: head.block.hash } };
}

/** Only explicit null is allowed; a missing or malformed field still fails. */
export function numberHeadOf(data: unknown): NumberGraphHead {
  const meta = object(object(data)._meta);
  const block = object(meta.block);
  requireValue(meta.hasIndexingErrors === false, "INDEXING_ERRORS");
  requireValue(typeof meta.deployment === "string" && /^[1-9A-HJ-NP-Za-km-z]{40,60}$/.test(meta.deployment), "MISSING_DEPLOYMENT");
  requireValue(Number.isSafeInteger(block.number) && (block.number as number) >= 0, "INVALID_BLOCK");
  requireValue(block.hash === null || (typeof block.hash === "string" && /^0x[0-9a-fA-F]{64}$/.test(block.hash)), "MISSING_BLOCK_HASH");
  return { deployment: meta.deployment, block: { number: block.number as number, hash: block.hash === null ? null : (block.hash as string).toLowerCase() } };
}

export function sameHead(expected: GraphHead, actual: GraphHead): void {
  requireValue(expected.deployment === actual.deployment, "DEPLOYMENT_CHANGED");
  requireValue(expected.block.hash === actual.block.hash && expected.block.number === actual.block.number, "BLOCK_CHANGED");
}
