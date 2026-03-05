#!/bin/bash
echo "Building project..."
swift build
if [ $? -ne 0 ]; then
    echo "Build failed! Not restarting."
    exit 1
fi

echo "Codesigning pecan-vm-launcher..."
codesign --entitlements Entitlements.plist -f -s "Apple Development: Byron Ellis (4BZX85G58E)" .build/debug/pecan-vm-launcher

# Kill any running pecan-server (which also manages vm-launcher)
pkill -f '.build/debug/pecan-server' 2>/dev/null
pkill -f '.build/debug/pecan-vm-launcher' 2>/dev/null

# Clean up stale sockets and pid files
rm -f .run/launcher.sock .run/grpc.sock .run/launcher.pid .run/server.pid

echo "Killed. Run ./dev_start.sh to start again."
