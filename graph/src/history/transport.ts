import { jsonBody } from "../graph.js";
import { requireValue } from "./types.js";
export type Requester = (
  query: string,
  variables?: Record<string, unknown>,
) => Promise<unknown>;
export function transport(
  endpoint: string,
  mode: "GATEWAY" | "STUDIO" | "LOCAL",
  key?: string,
): Requester {
  requireValue(
    ["GATEWAY", "STUDIO", "LOCAL"].includes(mode),
    "INVALID_PROVIDER_MODE",
  );
  const u = new URL(endpoint);
  requireValue(
    !u.username && !u.password && !u.search && !u.hash,
    "INVALID_ENDPOINT",
  );
  const approved =
    mode === "GATEWAY"
      ? u.protocol === "https:" &&
        u.hostname === "gateway.thegraph.com" &&
        /^\/api\/subgraphs\/id\/[a-zA-Z0-9]+$/.test(u.pathname)
      : mode === "STUDIO"
        ? u.protocol === "https:" &&
          u.hostname === "api.studio.thegraph.com" &&
          /^\/query\/[0-9]+\/[a-zA-Z0-9._/-]+$/.test(u.pathname)
        : u.protocol === "http:" &&
          ["127.0.0.1", "localhost", "[::1]"].includes(u.hostname) &&
          /^\/subgraphs\/name\/[a-zA-Z0-9_/-]+$/.test(u.pathname);
  requireValue(approved, "UNAPPROVED_ENDPOINT");
  if (mode === "GATEWAY") requireValue(key?.trim(), "MISSING_GRAPH_API_KEY");
  return async (query, variables = {}) => {
    let payload: Record<string, unknown>;
    try {
      const response = await fetch(endpoint, {
        method: "POST",
        redirect: "error",
        headers: {
          "Content-Type": "application/json",
          ...(key ? { Authorization: `Bearer ${key}` } : {}),
        },
        body: JSON.stringify({ query, variables }),
        signal: AbortSignal.timeout(30000),
      });
      requireValue(response.ok, "PROVIDER_HTTP");
      payload = await jsonBody(response);
    } catch {
      throw new Error("HISTORY_PROVIDER_FAILED");
    }
    requireValue(
      payload.errors === undefined ||
        (Array.isArray(payload.errors) && payload.errors.length === 0),
      "GRAPHQL_ERRORS",
    );
    requireValue(
      payload.data !== undefined && payload.data !== null,
      "MISSING_DATA",
    );
    return payload.data;
  };
}
