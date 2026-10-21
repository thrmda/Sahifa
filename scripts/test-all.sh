#!/usr/bin/env bash
#
# Runs every regression suite in scripts/test-*.sh and ends with one line per
# suite. Builds the app first, because test-formatting.sh and
# test-html-safety.sh link the swift-markdown objects out of a Debug build in
# build/DerivedData; pass --no-build when that build is already current.
#
# A failing suite does not stop the others, so one run reports everything.
# The exit status is non-zero if any suite failed. test-github-write.sh is
# opt-in (SAHIFA_TEST_REPO and SAHIFA_TEST_TOKEN) and counts as SKIP without
# them; test-github-store.sh and test-accounts.sh need the network.
#
# Usage: scripts/test-all.sh [--no-build]

set -uo pipefail

cd "$(dirname "$0")/.."

build=1
for arg in "$@"; do
  case "$arg" in
    --no-build) build=0 ;;
    *) echo "usage: $0 [--no-build]" >&2; exit 2 ;;
  esac
done

if (( build )); then
  echo "== build"
  if ! xcodebuild -project Sahifa.xcodeproj -scheme Sahifa -configuration Debug \
       -derivedDataPath build/DerivedData build -quiet; then
    echo "build failed" >&2
    exit 1
  fi
fi

logs="$(mktemp -d)"
trap 'rm -rf "$logs"' EXIT

failed=0
summary=()
for suite in scripts/test-*.sh; do
  name="$(basename "$suite" .sh)"
  name="${name#test-}"
  [[ "$name" == all ]] && continue

  echo
  echo "== $name"
  started=$SECONDS
  "$suite" 2>&1 | tee "$logs/$name.log"
  rc=${PIPESTATUS[0]}
  elapsed=$(( SECONDS - started ))

  if (( rc != 0 )); then
    status=FAIL
    failed=1
  elif grep -q '^SKIP' "$logs/$name.log" && ! grep -q '^PASS' "$logs/$name.log"; then
    status=SKIP
  else
    status=PASS
  fi
  summary+=("$(printf '%-5s %-20s %3ds' "$status" "$name" "$elapsed")")
done

echo
echo "== summary"
printf '%s\n' "${summary[@]}"
if (( failed )); then
  echo "SOME SUITES FAILED"
else
  echo "ALL SUITES PASSED"
fi
exit $failed
