#!/bin/zsh
set -euo pipefail

REPO_ROOT="${0:A:h:h}"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/private/tmp}/issues-core-tests.XXXXXX")"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
TARGET_TRIPLE="$(swiftc -print-target-info | sed -n 's/.*"triple": "\([^"]*\)".*/\1/p' | head -n 1)"

trap 'rm -rf -- "$TEST_ROOT"' EXIT

swiftc \
  -emit-library \
  -emit-module \
  -module-name IssuesCore \
  -enable-testing \
  -target "$TARGET_TRIPLE" \
  -sdk "$SDK_PATH" \
  -module-cache-path "$TEST_ROOT/module-cache" \
  -emit-module-path "$TEST_ROOT/IssuesCore.swiftmodule" \
  -o "$TEST_ROOT/libIssuesCore.dylib" \
  "$REPO_ROOT"/Sources/IssuesCore/*.swift

swiftc \
  -D CORE_TEST_HARNESS \
  -parse-as-library \
  -target "$TARGET_TRIPLE" \
  -sdk "$SDK_PATH" \
  -module-cache-path "$TEST_ROOT/module-cache" \
  -I "$TEST_ROOT" \
  -L "$TEST_ROOT" \
  -lIssuesCore \
  "$REPO_ROOT"/Tests/IssuesCoreTests/*.swift \
  -o "$TEST_ROOT/IssuesCoreFixtureTests"

DYLD_LIBRARY_PATH="$TEST_ROOT" "$TEST_ROOT/IssuesCoreFixtureTests"
