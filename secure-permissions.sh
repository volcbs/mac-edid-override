#!/bin/bash
set -euo pipefail
umask 077

if [ "$(uname -s)" != Darwin ]; then
    echo "Run this script on your Mac." >&2
    exit 1
fi
if [ "$#" -ne 0 ]; then
    echo "Run bash secure-permissions.sh without arguments." >&2
    exit 1
fi

INSTALL="$HOME/.config/edid-override"
BACKUPS="$HOME/.config/edid-override-backups"
AGENT="$HOME/Library/LaunchAgents/com.edid-override.plist"

# Validate every managed root before changing any permissions. Internal
# symlinks are skipped by find; their targets are never intentionally changed.
for path in "$INSTALL" "$BACKUPS" "$AGENT"; do
    if [ -L "$path" ]; then
        echo "A managed path is a symbolic link; no permissions changed: $path" >&2
        exit 1
    fi
    if [ -e "$path" ] && [ ! -O "$path" ]; then
        echo "A managed path belongs to another user; no permissions changed: $path" >&2
        exit 1
    fi
done

changed=0
for path in "$INSTALL" "$BACKUPS"; do
    if [ ! -d "$path" ]; then continue; fi
    chmod 700 "$path"
    find "$path" -type d -exec chmod 700 {} +
    # Preserve owner execute permission on installed programs and backup copies.
    find "$path" -type f -exec chmod go-rwx {} +
    changed=1
done
if [ -f "$AGENT" ]; then
    chmod 600 "$AGENT"
    changed=1
fi
if [ "$changed" -eq 0 ]; then
    echo "No installed EDID override files or backups found."
else
    echo "Restricted EDID override folders, files, backups, and startup entry to owner access."
    echo "Profile contents and display settings were not changed."
fi
