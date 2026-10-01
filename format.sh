#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"

case "${1:-}" in
    "")
        xcrun swift-format format --in-place --recursive Sources Package.swift
        ;;
    --check)
        xcrun swift-format lint --strict --recursive Sources Package.swift
        ;;
    *)
        print -u2 "Usage: ./format.sh [--check]"
        exit 2
        ;;
esac
