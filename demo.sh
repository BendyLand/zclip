#!/bin/bash

echo "Starting demo..."
echo "one" | xclip -sel clip
sleep 1
echo "zclip"
zclip
sleep 1
echo "zclip list"
zclip list
sleep 1
echo "zclip push two"
zclip push two
sleep 1
echo "echo \"three\" | zclip push"
echo "three" | zclip push
sleep 1
echo "echo \"four\" | xclip -sel clip"
echo "four" | xclip -sel clip
sleep 1
echo "zclip list"
zclip list
sleep 1
echo "zclip get 2"
zclip get 2
sleep 1
echo "xclip -sel clip -o"
xclip -sel clip -o
sleep 1
echo "zclip exit"
zclip exit
echo "Thank you for watching the demo 😊"

