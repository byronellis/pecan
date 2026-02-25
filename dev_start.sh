#!/bin/bash
mkdir -p .run
echo $$ > .run/server_loop.pid

echo "Starting pecan-server loop..."
while true; do
    .build/debug/pecan-server > .run/server.log 2>&1 &
    SERVER_PID=$!
    echo $SERVER_PID > .run/server.pid
    wait $SERVER_PID
    EXIT_CODE=$?
    echo "Server exited with code $EXIT_CODE. Restarting in 1s..."
    sleep 1
done
