#!/bin/bash

# Stop the server using the PID from the status file if available
if [ -f .run/server.json ]; then
    SERVER_PID=$(grep -o '"pid"[[:space:]]*:[[:space:]]*[0-9]*' .run/server.json | grep -o '[0-9]*$')
    if [ -n "$SERVER_PID" ]; then
        kill "$SERVER_PID" 2>/dev/null && echo "Stopped pecan-server (pid $SERVER_PID)"
    fi
    rm -f .run/server.json
else
    # Fallback: kill by name
    pkill -f '.build/debug/pecan-server' 2>/dev/null
    pkill -f '.build/release/pecan-server' 2>/dev/null
fi

# Kill any dangling pecan-agent or pecan-vm-launcher processes
pkill -f pecan-agent 2>/dev/null
pkill -f pecan-vm-launcher 2>/dev/null

# Clean up sockets
rm -f .run/launcher.sock .run/grpc.sock

echo "Server, launcher, and agents stopped."
