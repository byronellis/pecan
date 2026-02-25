#!/bin/bash
if [ -f .run/server_loop.pid ]; then
    kill $(cat .run/server_loop.pid) 2>/dev/null
    rm .run/server_loop.pid
fi
if [ -f .run/server.pid ]; then
    kill $(cat .run/server.pid) 2>/dev/null
    rm .run/server.pid
fi

# Kill any dangling pecan-agent processes
pkill -f pecan-agent 2>/dev/null

echo "Server and agents stopped."
