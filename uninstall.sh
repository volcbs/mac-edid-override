#!/bin/bash
set -euo pipefail
INSTALL="$HOME/.config/edid-override"
BACKUPS="$HOME/.config/edid-override-backups"
AGENT="$HOME/Library/LaunchAgents/com.edid-override.plist"
USER_ID="$(id -u)"
JOB="gui/$USER_ID/com.edid-override"
if [ "$(uname -s)" != Darwin ]; then echo "Run this uninstaller on your Mac." >&2; exit 1; fi
if [ -L "$INSTALL" ] || [ -L "$AGENT" ]; then echo "Symlinked installation paths; no changes made." >&2; exit 1; fi
# Clearing the live override is best-effort: a missing monitor, broken
# configuration, or unavailable private API must not block file removal.
if [ -x "$INSTALL/edid_override" ]; then
    if ! "$INSTALL/edid_override" --reset; then
        echo "Could not clear the live override. Restart your Mac after uninstalling." >&2
    fi
fi
launchctl bootout "$JOB" >/dev/null 2>&1 || true
if launchctl print "$JOB" >/dev/null 2>&1; then echo "Background job remains loaded; keeping files." >&2; exit 1; fi
# Also stop copies started manually outside launchd, restricted to this user.
pkill -u "$USER_ID" -x edid_override >/dev/null 2>&1 || true
for attempt in 1 2 3 4 5 6 7 8 9 10; do
    if ! pgrep -u "$USER_ID" -x edid_override >/dev/null 2>&1; then break; fi
    sleep 0.1
done
if pgrep -u "$USER_ID" -x edid_override >/dev/null 2>&1; then
    echo "An edid_override process is still running; keeping files." >&2; exit 1
fi
rm -f "$AGENT"
rm -rf "$INSTALL" "$BACKUPS"
# Original upstream versions used this shared temporary location. Remove it
# only if owned by the current user.
if [ -O /tmp/edid-override.log ]; then rm -f /tmp/edid-override.log; fi
launchctl enable "$JOB" >/dev/null 2>&1 || true
echo "Removed EDID override files, startup entry, profiles, logs, and all saved backups."
