import { jsonBody, object } from "./graph.js";
import { AnalyticsError, requireValue } from "./types.js";
import type { BlockHeader } from "./types.js";

export type RpcRequest = (method: "eth_chainId" | "eth_getBlockByNumber", params: unknown[]) => Promise<unknown>;

/** Endpoint comes from operator environment, never user query parameters. No writes. */
export function rpcClient(endpoint: string | undefined, fetcher: typeof fetch = fetch): RpcRequest {
  requireValue(typeof endpoint === "string" && endpoint.length > 0, "MISSING_GRAPH_RPC_URL");
  let url: URL;
  try { url = new URL(endpoint); } catch { throw new AnalyticsError("INVALID_RPC_ENDPOINT"); }
  requireValue(url.protocol === "https:" && !url.username && !url.password && !url.hash, "INVALID_RPC_ENDPOINT");
  return async (method, params) => {
    requireValue(method === "eth_chainId" || method === "eth_getBlockByNumber", "UNAPPROVED_RPC_METHOD");
    requireValue(method === "eth_chainId" ? params.length === 0
      : params.length === 2 && params[1] === false && typeof params[0] === "string"
        && /^(finalized|0x(?:0|[1-9a-f][0-9a-f]*))$/.test(params[0]), "INVALID_RPC_PARAMS");
    try {
      const response = await fetcher(url, {
        method: "POST", redirect: "error", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }), signal: AbortSignal.timeout(15_000),
      });
      requireValue(response.ok, "RPC_HTTP");
      const payload = await jsonBody(response);
      requireValue(payload.jsonrpc === "2.0" && payload.id === 1, "RPC_RESPONSE_MISMATCH");
      requireValue(payload.error === undefined, "RPC_ERROR");
      requireValue(payload.result !== undefined && payload.result !== null, "RPC_DATA_UNAVAILABLE");
      return payload.result;
    } catch (error) {
      if (error instanceof AnalyticsError) throw error;
      // Provider URLs and bodies can contain credentials. Never reflect them.
      throw new AnalyticsError("RPC_REQUEST_FAILED");
    }
  };
}

export function quantity(value: unknown): number {
  requireValue(typeof value === "string" && /^0x(?:0|[1-9a-fA-F][0-9a-fA-F]*)$/.test(value) && value.length <= 16, "INVALID_RPC_QUANTITY");
  const number = Number(BigInt(value));
  requireValue(Number.isSafeInteger(number), "INVALID_RPC_QUANTITY");
  return number;
}

export async function blockHeader(rpc: RpcRequest, tag: string): Promise<BlockHeader> {
  const raw = object(await rpc("eth_getBlockByNumber", [tag, false]));
  requireValue(typeof raw.hash === "string" && /^0x[0-9a-fA-F]{64}$/.test(raw.hash), "INVALID_RPC_HASH");
  const header = { number: quantity(raw.number), hash: raw.hash.toLowerCase(), timestamp: quantity(raw.timestamp) };
  if (tag !== "finalized") requireValue(header.number === quantity(tag), "RPC_BLOCK_MISMATCH");
  return header;
}
