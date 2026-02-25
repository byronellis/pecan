#!/bin/bash
echo "Building project..."
swift build
if [ $? -ne 0 ]; then
    echo "Build failed! Not restarting."
    exit 1
fi

./dev_stop.sh
./dev_start.sh &
echo "Server restarted in background. Tail .run/server.log to see output."
