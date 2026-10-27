#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/ModuleCache
xcrun swiftc -parse-as-library -module-cache-path build/ModuleCache Sources/WriterCore.swift Sources/SynonymEngine.swift Tests/CoreTests.swift -o build/core-tests
build/core-tests
