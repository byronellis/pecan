#!/bin/bash
echo "Building project..."
swift build
if [ $? -ne 0 ]; then
    echo "Build failed! Not restarting."
    exit 1
fi

echo "Codesigning pecan-vm-launcher..."
codesign --entitlements Entitlements.plist -f -s "Apple Development: Byron Ellis (4BZX85G58E)" .build/debug/pecan-vm-launcher

# Stop any running server
./dev_stop.sh

echo "Starting pecan-server..."
exec .build/debug/pecan-server
