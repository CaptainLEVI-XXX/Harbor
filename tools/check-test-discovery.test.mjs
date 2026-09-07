import assert from "node:assert/strict";
import { test } from "node:test";
import { validateDiscovery } from "./check-test-discovery.mjs";

const file = "test/Example.t.sol";
const manifest = {
  suites: { [file]: { ExampleTest: ["test_Works"] } },
  profiles: { default: [file] },
};
const discovered = { [file]: { ExampleTest: ["test_Works"] } };

test("accepts a discovered required suite", () => {
  assert.equal(validateDiscovery(discovered, manifest, "default", [file]), 1);
});
test("rejects an unregistered profile", () => {
  assert.throws(() => validateDiscovery(discovered, manifest, "fork", [file]), /No required suites/);
});
test("rejects an empty or filtered run", () => {
  assert.throws(() => validateDiscovery({}, manifest, "default", [file]), /Discovered files/);
});
test("rejects an empty contract", () => {
  assert.throws(() => validateDiscovery({ [file]: { ExampleTest: [] } }, manifest, "default", [file]), /Empty suite/);
});
test("rejects a missing required test", () => {
  assert.throws(() => validateDiscovery({ [file]: { ExampleTest: ["test_Other"] } }, manifest, "default", [file]), /Required test/);
});
test("rejects an unregistered test file", () => {
  assert.throws(() => validateDiscovery(discovered, manifest, "default", [file, "test/Hidden.t.sol"]), /Unregistered/);
});
test("rejects a suite without an execution profile", () => {
  const extra = "test/Orphan.t.sol";
  const orphan = { ...manifest, suites: { ...manifest.suites, [extra]: { OrphanTest: ["test_Works"] } } };
  assert.throws(() => validateDiscovery(discovered, orphan, "default", [file, extra]), /no execution profile/);
});
