#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"

# Verify existing checkouts without resetting or overwriting local changes.
for dependency in lib/forge-std lib/solady; do
  if [[ ! -e "$dependency/.git" ]]; then
    git submodule update --init --recursive -- "$dependency"
  fi
done
node --input-type=module -e '
  import { readFileSync } from "node:fs";
  import { execFileSync } from "node:child_process";
  const pins = JSON.parse(readFileSync("foundry.lock", "utf8"));
  for (const [path, pin] of Object.entries(pins)) {
    const actual = execFileSync("git", ["-C", path, "rev-parse", "HEAD"], {encoding: "utf8"}).trim();
    const changes = execFileSync("git", ["-C", path, "status", "--porcelain"], {encoding: "utf8"}).trim();
    if (actual !== pin.tag.rev || changes) throw new Error(`Dependency is modified or at the wrong revision: ${path}`);
  }
'

dependency_tmp="$(mktemp -d "${TMPDIR:-/tmp}/harbor-deps.XXXXXX")"
cleanup() {
  # Only the exact directory allocated by this invocation is disposable.
  case "$dependency_tmp" in
    "${TMPDIR:-/tmp}"/harbor-deps.*) rm -rf -- "$dependency_tmp" ;;
  esac
}
trap cleanup EXIT

install_source() {
  local name="$1" revision="$2" checksum="$3"
  local archive="$dependency_tmp/$name.tar.gz"
  local unpacked="$dependency_tmp/$name-$revision"
  local destination="$repository_root/lib/$name"

  curl --fail --silent --show-error --location --retry 2 \
    --connect-timeout 15 --max-time 120 \
    "https://codeload.github.com/1inch/$name/tar.gz/$revision" --output "$archive"
  node --input-type=module - "$archive" "$checksum" <<'NODE'
import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";
const [archive, expected] = process.argv.slice(2);
const actual = createHash("sha256").update(readFileSync(archive)).digest("hex");
if (actual !== expected) throw new Error("Dependency archive checksum mismatch");
NODE
  tar -xzf "$archive" -C "$dependency_tmp"
  if [[ -e "$destination" || -L "$destination" ]]; then
    if [[ -L "$destination" ]] || ! diff -qr "$unpacked" "$destination"; then
      printf 'Refusing to overwrite modified dependency: %s\n' "$name" >&2
      return 1
    fi
  else
    mv "$unpacked" "$destination"
  fi
  printf 'Verified %s at %s\n' "$name" "$revision"
}

install_source aqua 9c5c42e5840e8741fba3597c48456c9510212b66 \
  462d3e4cd565818b99566ca2f9604efd21e549d33c1f906118fb2174c9a12c1d
install_source swap-vm f09a41e689240adc645934f965c8061749397cd2 \
  9a2465b938baba05799c65966d8cbf49a1677c8fc3c56b5e9f08ac8ce950d608

npm ci --prefix dependencies --ignore-scripts --no-audit --no-fund \
  --fetch-timeout=15000 --fetch-retries=0
