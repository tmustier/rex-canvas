#!/bin/sh
# Builds bin/rex-canvas. Usage: ./build.sh
set -eu
cd "$(dirname "$0")"
mkdir -p bin
swiftc -O -swift-version 5 -o bin/rex-canvas Sources/*.swift
echo "built $(pwd)/bin/rex-canvas"
