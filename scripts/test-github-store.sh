#!/usr/bin/env bash
#
# Reads this project's own public GitHub repository to check the remote store:
# folder listing, file contents, the version marker, and error handling.
#
# Needs no credentials — anonymous GitHub access is enough for a public repo,
# and is limited to 60 requests an hour. A network failure or a hit rate limit
# reports SKIPPED rather than failing.
#
# Usage: scripts/test-github-store.sh

set -euo pipefail

cd "$(dirname "$0")/.."

BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

swiftc -O \
  Sahifa/Models/Source.swift \
  Sahifa/Models/DirectoryWatcher.swift \
  Sahifa/Models/DocumentStore.swift \
  Sahifa/Models/GitHubStore.swift \
  Sahifa/Models/DocumentModel.swift \
  Sahifa/Models/WindowState.swift \
  Sahifa/Models/AppModel.swift \
  Tests/GitHubStore/main.swift \
  -o "$BUILD/github-store"

"$BUILD/github-store"
