#!/bin/bash
set -e

echo "Building project (debug)..."
make debug

mkdir -p .run
rm -f .run/launcher.sock .run/grpc.sock .run/server.json

echo "Starting pecan-server (manages vm-launcher automatically)..."
exec .build/arm64-apple-macosx/debug/pecan-server
