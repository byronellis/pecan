#!/bin/bash
echo "Building project..."
swift build
if [ $? -ne 0 ]; then
    echo "Build failed! Not restarting."
    exit 1
fi

if [ -f .run/server.pid ]; then
    kill $(cat .run/server.pid) 2>/dev/null
    rm .run/server.pid
fi

# Kill any dangling pecan-agent processes
pkill -f pecan-agent 2>/dev/null

echo "Server killed. The dev_start.sh loop will automatically restart it in 1s."
