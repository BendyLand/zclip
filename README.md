# zclip 

zclip is a lightweight clipboard daemon for Linux written in Zig.
It sits in the background, watches the X11 clipboard, and automatically builds a unique list of recent clipboard entries.
A small CLI talks to the daemon over a UNIX domain socket so you can list, recall, save/load to SQLite, or clear items without an entire GUI manager.

> X11 only. Wayland native clipboards aren’t supported.

## Features

 - Daemonized background service (zclip with no args)
 - Automatic capture of clipboard changes using XFixes (with periodic fallback polling)
 - De-duplication and stable insertion order
 - Fast recall: set the X11 clipboard to any saved entry via zclip get N
 - Manual push: pipe data to zclip push (reads stdin)
 - Persistence: save/load the set to /tmp/zclip.db (SQLite)
 - Simple IPC over a UNIX socket at /tmp/zclip.sock
 - Crash-safe ergonomics: clear messages, easy recovery (remove stale socket, check logs)

## How it works (high level)

 - On start, the daemon creates an invisible X11 window and registers for XFixes selection owner notifications on the CLIPBOARD atom.
 - When a new owner appears, it requests UTF8_STRING and stores the text if it’s new.
 - It also performs periodic polling as a fallback.
   - This was also necessary to be able to push specific entries *back* to the system clipboard (xclip).
 - Items live in a MasterList (string → insertion index).
   - A Tray view is derived by sorting keys by index for display.
 - The CLI connects to /tmp/zclip.sock and sends plain-text commands (e.g., list, get 3).
 - `get` forks a short-lived helper that temporarily becomes the selection owner, serves the requestor, then exits.

## Requirements

 - Zig (recent stable)
 - X11 headers & libraries: libX11, libXfixes
 - dlopen/dlsym (libdl) and POSIX bits (poll, signals)
 - SQLite plus a Zig SQLite binding 

> To easily install the requirement, run the following command (Ubuntu/Debian):
```bash
    sudo apt install zig libx11-dev libxfixes-dev libdl-dev sqlite3 libsqlite3-dev
```

### Zig dependency note

This program expects a Zig-importable sqlite package.
If you don't have that yet, add a dependency that exposes @import("sqlite") and make sure the build links against sqlite3.
## Build & Run

```bash
# The 'safe' release option is what is used during testing.
# Behavior or performance may vary with other options.
zig build --release=safe 

# Start the daemon (no args). It will daemonize itself.
# Logs go to: /tmp/zclip.log
# Socket is at: /tmp/zclip.sock
./zig-out/bin/zclip
# It is recommended to move the binary to /usr/local/bin 
# or add the binary's directory to your system $PATH.
# That way you can simply run `zclip`. 
# You may also alias it to something like `zc` for ease of use. 
# (For the remainder of this README, I will use `zclip` as the working command.)
```

## Quick start

```bash
# Show help (client-side help, no daemon needed; still works if daemon is running)
zclip help

# Start daemon (no args):
zclip

# Copy something in your X11 session (Ctrl+C somewhere or run):
echo "This is a test" | xclip -sel clip

# List saved items:
zclip list

# Set clipboard to item 3 (and print it to stdout as a response):
zclip get 3

# Manually push via stdin (reads all stdin):
echo -n "hello world" | zclip push

# Save current set to sqlite:
zclip save

# Load previously saved set from sqlite:
zclip load

# Prints the number of saved items:
zclip len

# Clear all saved items (does not kill daemon):
zclip clear

# Ask daemon to exit cleanly:
zclip exit
```

## Command reference (client → daemon)
`zclip...`
 - `push <text>` — Add an entry (client usually provides via stdin).
 - `get <n>`     — Set system clipboard to entry n (1-based; out-of-range clamps to ends).
 - `list`        — Print all items with 1-based indices.
 - `len`         — Print the number of tray items.
 - `clear`       — Remove all saved items from memory.
 - `save`        — Persist current set to /tmp/zclip.db.
 - `load`        — Load from /tmp/zclip.db (replaces in-memory set).
 - `help`        — Prints the help menu (same as zclip help).
 - `exit`        — Shut down the daemon (removes /tmp/zclip.sock).
 - `reset`       — Convenience macro:
     - Pushes "", performs `get 10000` (effectively last item), then `clear`s everything.
     - Result: both the current clipboard entry and in-memory list end up empty.

## Paths & files

 - UNIX socket: /tmp/zclip.sock
 - Daemon log: /tmp/zclip.log
     - (also a short-lived /tmp/zclip-set.log for the forked setter helper)
 - SQLite DB: /tmp/zclip.db

## Troubleshooting

“Daemon not running”
 - Start it with `zclip` (no args). Check /tmp/zclip.log.

“Connection refused” or commands hang
 - The daemon likely crashed or exited uncleanly. Remove stale socket:
 - `rm -f /tmp/zclip.sock` then start the daemon again.

No items captured
 - Ensure you’re actually on X11. Wayland native sessions won’t work.
 - Make sure libXfixes is available; without it you’ll rely on polling only.
 - Some apps set non-UTF8 clipboard formats; zclip requests UTF8_STRING.

Permission/SELinux/AppArmor issues
 - Check that your user can create and connect to /tmp/zclip.sock, and that the environment has access to the X11 display.

## Security & Privacy Notes

 - Clipboard contents are stored in memory and can be persisted to disk in plain text (/tmp/zclip.db).
 - If you copy secrets, be aware they may linger there.
 - Consider relocating the socket/DB to a private runtime dir for multi-user systems.

## License

This project is licensed under the [MIT License](./LICENSE).

