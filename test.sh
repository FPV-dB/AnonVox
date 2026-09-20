#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 -O VoiceDSP.swift VoiceScramblerEngine.swift AudioDevices.swift LicenseManager.swift Tests/AudioRegression.swift -o build/AudioRegression
build/AudioRegression
