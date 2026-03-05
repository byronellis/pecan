#!/bin/bash
set -e

echo "Building project..."
swift build
echo "Codesigning pecan-vm-launcher..."
codesign --entitlements Entitlements.plist -f -s "Apple Development: Byron Ellis (4BZX85G58E)" .build/debug/pecan-vm-launcher

mkdir -p .run
rm -f .run/launcher.sock .run/grpc.sock

echo "Starting pecan-server (manages vm-launcher automatically)..."
exec .build/debug/pecan-server
