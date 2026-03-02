#!/bin/bash
echo "Building project..."
swift build
if [ $? -ne 0 ]; then
    echo "Build failed! Not restarting."
    exit 1
fi

echo "Codesigning pecan-vm-launcher and pecan-builder..."
codesign --entitlements Entitlements.plist -f -s "Apple Development: Byron Ellis (4BZX85G58E)" .build/debug/pecan-vm-launcher
codesign --entitlements Entitlements.plist -f -s "Apple Development: Byron Ellis (4BZX85G58E)" .build/debug/pecan-builder

if [ -f .run/launcher.pid ]; then
    kill $(cat .run/launcher.pid) 2>/dev/null
    rm .run/launcher.pid
fi

if [ -f .run/server.pid ]; then
    kill $(cat .run/server.pid) 2>/dev/null
    rm .run/server.pid
fi

# Kill any dangling pecan-agent processes
pkill -f pecan-agent 2>/dev/null

echo "Server and launcher killed. The dev_start.sh loop will automatically restart in 1s."
