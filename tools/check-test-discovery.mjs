import { execFileSync } from "node:child_process";
import { readFileSync, readdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export function validateDiscovery(discovered, manifest, profile, files) {
  const expectedFiles = manifest.profiles[profile];
  if (!expectedFiles?.length) throw new Error(`No required suites registered for profile: ${profile}`);
  for (const file of files) {
    if (!manifest.suites[file]) throw new Error(`Unregistered test file: ${file}`);
    if (!Object.values(manifest.profiles).some((entries) => entries.includes(file))) {
      throw new Error(`Test file has no execution profile: ${file}`);
    }
  }
  const actualFiles = Object.keys(discovered).sort();
  if (JSON.stringify(actualFiles) !== JSON.stringify([...expectedFiles].sort())) {
    throw new Error(`Discovered files do not match the required ${profile} suites`);
  }
  let count = 0;
  for (const file of expectedFiles) {
    const expectedContracts = manifest.suites[file];
    if (!expectedContracts || !Object.keys(expectedContracts).length) {
      throw new Error(`Missing contract manifest: ${file}`);
    }
    for (const [contract, required] of Object.entries(expectedContracts)) {
      const tests = discovered[file]?.[contract];
      if (!required.length || !tests?.length) throw new Error(`Empty suite: ${file}:${contract}`);
      for (const test of required) {
        if (!tests.includes(test)) throw new Error(`Required test missing: ${contract}.${test}`);
      }
      count += tests.length;
    }
  }
  return count;
}

function testFiles(path = "test") {
  return readdirSync(path, { withFileTypes: true }).flatMap((entry) => {
    const child = `${path}/${entry.name}`;
    if (entry.isDirectory()) return testFiles(child);
    return entry.isFile() && entry.name.endsWith(".t.sol") ? [child] : [];
  });
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  process.chdir(resolve(dirname(fileURLToPath(import.meta.url)), ".."));
  const profile = process.argv[2] ?? "default";
  const manifest = JSON.parse(readFileSync("tools/test-suites.json", "utf8"));
  if (!manifest.profiles[profile]) throw new Error(`No required suites registered for profile: ${profile}`);
  const output = execFileSync("forge", ["test", "--list", "--json"], {
    encoding: "utf8",
    env: { ...process.env, FOUNDRY_PROFILE: profile },
    maxBuffer: 16 * 1024 * 1024,
  });
  const count = validateDiscovery(JSON.parse(output), manifest, profile, testFiles());
  console.log(`${profile}: verified ${count} tests across ${manifest.profiles[profile].length} files`);
}
