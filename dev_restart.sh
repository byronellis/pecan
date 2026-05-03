#!/bin/bash
set -e

echo "Building project (debug)..."
make debug

./dev_stop.sh

echo "Starting pecan-server..."
exec .build/arm64-apple-macosx/debug/pecan-server
