#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
mkdir -p build/checks
xcrun swiftc -swift-version 5 Shared/*.swift Mac/PenEvents.swift Tests/main.swift -o build/checks/BridgeChecks
build/checks/BridgeChecks "$@"
xcrun swiftc -swift-version 5 -parse-as-library Shared/*.swift Mac/PenEvents.swift Mac/DrawingDemo.swift Tests/DrawingDemoChecks.swift -o build/checks/DrawingDemoChecks
build/checks/DrawingDemoChecks
