#!/bin/bash
mkdir -p .run
echo $$ > .run/start_loop.pid

# Clean up stale sockets
rm -f .run/launcher.sock

# Start the VM launcher first
echo "Starting pecan-vm-launcher..."
.build/debug/pecan-vm-launcher > .run/launcher.log 2>&1 &
LAUNCHER_PID=$!
echo $LAUNCHER_PID > .run/launcher.pid
echo "VM Launcher started (PID $LAUNCHER_PID)"

# Wait for the launcher socket to appear
sleep 0.5

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
