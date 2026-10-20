#!/bin/bash
# Run usage parsing regressions with Command Line Tools; no full Xcode needed.
set -euo pipefail
cd "$(dirname "$0")"

TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aiusage-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

swiftc \
    Sources/UsageBar/Models.swift \
    Sources/UsageBar/Format.swift \
    Sources/UsageBar/ClaudeUsageParser.swift \
    Sources/UsageBar/ClaudeWebSession.swift \
    Sources/UsageBar/CodexAppServer.swift \
    Sources/UsageBar/UsageStore.swift \
    Tests/ClaudeUsageParserTests.swift \
    -o "$TEST_DIR/ClaudeUsageParserTests"
"$TEST_DIR/ClaudeUsageParserTests"
