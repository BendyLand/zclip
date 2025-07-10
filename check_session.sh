#!/bin/bash

ps -eo pid,ppid,cmd | head -1
ps -eo pid,ppid,cmd | rg zclip

