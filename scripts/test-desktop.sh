#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
SCRATCH_DIR="${ISSUES_BUILD_DIR:-/private/tmp/issues-swift-build}"
export CLANG_MODULE_CACHE_PATH=/private/tmp/issues-review-clang
export SWIFT_MODULECACHE_PATH=/private/tmp/issues-review-swift
swift build --target IssuesDesktop --scratch-path "$SCRATCH_DIR" --cache-path /private/tmp/issues-spm-cache --disable-sandbox
PRODUCTS="$(swift build --scratch-path "$SCRATCH_DIR" --cache-path /private/tmp/issues-spm-cache --disable-sandbox --show-bin-path)"
ACCESSOR="$PRODUCTS/IssuesDesktop.build/DerivedSources/resource_bundle_accessor.swift"
if [ ! -f "$ACCESSOR" ]; then
  ACCESSOR="$SCRATCH_DIR/out/Intermediates.noindex/Issues.build/Debug/Issues-p.build/DerivedSources/resource_bundle_accessor.swift"
fi
if [ ! -f "$ACCESSOR" ]; then
  printf 'SwiftPM resource accessor was not found. Run the desktop build with a supported Swift toolchain.\n' >&2
  exit 1
fi
if [ -f "$PRODUCTS/IssuesCore.o" ]; then
  CORE_OBJECTS=("$PRODUCTS/IssuesCore.o")
else
  shopt -s nullglob
  CORE_OBJECTS=("$PRODUCTS"/IssuesCore.build/*.swift.o)
  if [ "${#CORE_OBJECTS[@]}" -eq 0 ]; then
    printf 'IssuesCore build objects were not found in %s\n' "$PRODUCTS" >&2
    exit 1
  fi
fi
swiftc -parse-as-library -I "$PRODUCTS" -I "$PRODUCTS/Modules" \
  Sources/IssuesDesktop/AppStore.swift Sources/IssuesDesktop/WindowCoordinator.swift \
  "$ACCESSOR" Tests/IssuesDesktopRegression.swift Tests/ProjectSelectionRegression.swift Tests/ComposerRegression.swift \
  "${CORE_OBJECTS[@]}" -framework AppKit -framework WebKit -framework Security -framework Carbon \
  -o /private/tmp/issues-desktop-regression
/private/tmp/issues-desktop-regression
