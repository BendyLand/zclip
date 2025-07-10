#!/bin/bash

pids=$(pgrep -f "^./zig-out/bin/zclip$")
if [ -n "$pids" ]; then
    for id in $pids; do
        echo "Killing $id"
        kill $id;
    done
    echo "Session killed"
else
    echo "No zclip daemon running"
fi

rm /tmp/zclip.sock

