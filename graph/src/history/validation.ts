export function requireValue(
  condition: unknown,
  code: string,
): asserts condition {
  if (!condition) throw new Error(code);
}
export function objectNever(value: unknown): Record<string, unknown> {
  requireValue(
    value !== null && typeof value === "object" && !Array.isArray(value),
    "INVALID_OBJECT",
  );
  return value as Record<string, unknown>;
}
