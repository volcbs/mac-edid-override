#!/bin/bash
set -euo pipefail
INSTALL="$HOME/.config/edid-override"
AGENT="$HOME/Library/LaunchAgents/com.edid-override.plist"
DOMAIN="gui/$(id -u)"
JOB="$DOMAIN/com.edid-override"
if [ -L "$INSTALL" ] || [ -L "$AGENT" ]; then echo "Symlinked installation paths; no changes made." >&2; exit 1; fi
if [ ! -f "$INSTALL/profiles-backup-path" ]; then echo "No recorded upgrade backup." >&2; exit 1; fi
BACKUP="$(cat "$INSTALL/profiles-backup-path")"
case "$BACKUP" in
    "$HOME/.config/edid-override-backups/"*) ;;
    *) echo "Unexpected backup location; no changes made." >&2; exit 1 ;;
esac
if [ ! -d "$BACKUP" ] || [ ! -f "$BACKUP/was-loaded" ] || [ ! -f "$BACKUP/was-disabled" ]; then
    echo "Backup is incomplete or missing; no changes made." >&2; exit 1
fi
WAS_LOADED="$(cat "$BACKUP/was-loaded")"
WAS_DISABLED="$(cat "$BACKUP/was-disabled")"
case "$WAS_LOADED:$WAS_DISABLED" in 0:0|0:1|1:0|1:1) ;; *) echo "Invalid backup state." >&2; exit 1 ;; esac
"$INSTALL/edid_override" --reset
rm -rf "$INSTALL"
rm -f "$AGENT"
if [ -d "$BACKUP/install" ]; then cp -R "$BACKUP/install" "$INSTALL"; fi
if [ -f "$BACKUP/agent.plist" ]; then cp "$BACKUP/agent.plist" "$AGENT"; fi
if [ "$WAS_DISABLED" -eq 1 ]; then launchctl disable "$JOB"; else launchctl enable "$JOB"; fi
if [ "$WAS_LOADED" -eq 1 ] && [ -f "$AGENT" ]; then launchctl bootstrap "$DOMAIN" "$AGENT"; fi
echo "Previous installation and its previous monitor-selection behavior restored. Backup retained."
