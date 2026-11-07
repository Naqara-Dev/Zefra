#!/bin/bash
# Compiles Zefra's logic, the part that touches no hardware, with Tests/CoreTests.swift and runs it.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
swiftc -swift-version 6 -parse-as-library -O -o "$OUT/core-tests" \
  Zefra/Core/*.swift Shared/FanGuard.swift Shared/SMC.swift Tests/CoreTests.swift -framework IOKit
"$OUT/core-tests"
