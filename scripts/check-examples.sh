#!/bin/bash
set -euo pipefail

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

(
  cd Examples/Plugins/AllCapabilitiesPlugin
  swift format lint --strict --recursive Sources Package.swift
  swift build -c release -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
)

echo "Swift plugin examples verified"
