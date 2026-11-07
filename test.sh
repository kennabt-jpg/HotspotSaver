#!/bin/zsh
# Builds and runs the unit tests. Read-only: no apps are quit and nothing is unloaded.
set -euo pipefail
cd "${0:A:h}"

srcs=(Sources/*.swift)
srcs=(${srcs:#Sources/main.swift})
mkdir -p build
swiftc -swift-version 5 -target "$(uname -m)-apple-macos14.0" "${srcs[@]}" Tests/main.swift -o build/run-tests
./build/run-tests
