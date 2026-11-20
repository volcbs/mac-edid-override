#!/bin/bash
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "$0")" && pwd)"
INSTALL="$HOME/.config/edid-override"
AGENT="$HOME/Library/LaunchAgents/com.edid-override.plist"
DOMAIN="gui/$(id -u)"
JOB="$DOMAIN/com.edid-override"
BUILD=""
BACKUP=""
MUTATED=0
COMPLETE=0
WAS_LOADED=0
WAS_DISABLED=0
HAD_CONFIG=0

finish() {
    local status=$?
    trap - EXIT
    set +e
    if [ "$status" -ne 0 ] && [ "$MUTATED" -eq 1 ] && [ "$COMPLETE" -eq 0 ]; then
        echo "Upgrade failed. Restoring the previous files and startup state..." >&2
        launchctl bootout "$JOB" >/dev/null 2>&1 || true
        "$BUILD/edid_override" --clear-config "$BUILD/profiles.json" || true
        rm -rf "$INSTALL"
        rm -f "$AGENT"
        local restored=1
        if [ -d "$BACKUP/install" ]; then cp -R "$BACKUP/install" "$INSTALL" || restored=0; fi
        if [ -f "$BACKUP/agent.plist" ]; then cp "$BACKUP/agent.plist" "$AGENT" || restored=0; fi
        if [ "$WAS_DISABLED" -eq 1 ]; then
            launchctl disable "$JOB" >/dev/null 2>&1 || restored=0
        else
            launchctl enable "$JOB" >/dev/null 2>&1 || restored=0
        fi
        if [ "$WAS_LOADED" -eq 1 ] && [ -f "$AGENT" ]; then
            launchctl bootstrap "$DOMAIN" "$AGENT" >/dev/null 2>&1 || restored=0
        fi
        if [ "$restored" -eq 1 ]; then
            echo "Previous installation restored with its previous monitor-selection behavior." >&2
        else echo "Restore was incomplete. Backup retained at: $BACKUP" >&2; fi
    fi
    if [ -n "$BUILD" ]; then rm -rf "$BUILD"; fi
    exit "$status"
}
trap finish EXIT

if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
    echo "Use native Terminal on an Apple Silicon Mac." >&2; exit 1
fi
if ! xcode-select -p >/dev/null 2>&1; then
    echo "Install Apple's tools first: xcode-select --install" >&2; exit 1
fi
if [ -n "${EDID_OVERRIDE_ROOT:-}" ]; then
    echo "Unset EDID_OVERRIDE_ROOT before running the installer." >&2; exit 1
fi
if [ -L "$INSTALL" ] || [ -L "$AGENT" ]; then
    echo "Installation paths are symlinks; no changes made." >&2; exit 1
fi
if [ "$#" -ne 0 ]; then echo "Run bash install.sh without arguments." >&2; exit 1; fi

BUILD="$(mktemp -d "${TMPDIR:-/tmp}/edid-profiles-build.XXXXXX")"
echo "Compiling the multi-profile version..."
bash "$ROOT/build.sh" "$BUILD"
if [ -e "$INSTALL/profiles.json" ]; then
    HAD_CONFIG=1
    cp "$INSTALL/profiles.json" "$BUILD/profiles-before.json"
fi
"$BUILD/edid_override" --prepare-config "$ROOT/default-profiles.json" "$BUILD/profiles.json"
"$BUILD/edid_override" --validate-config "$BUILD/profiles.json"
echo "Read-only check of connected monitor identities..."
if ! "$BUILD/edid_override" --probe-config "$BUILD/profiles.json"; then
    echo "No enabled profile could be uniquely verified. Existing installation unchanged." >&2
    echo "Register your own factory/custom EDIDs, connect that monitor, and retry." >&2
    exit 1
fi
# Detect profile edits made while compiling/probing, before replacing anything.
if [ "$HAD_CONFIG" -eq 1 ]; then
    if ! cmp -s "$BUILD/profiles-before.json" "$INSTALL/profiles.json"; then
        echo "Profiles changed during preflight. No upgrade performed; retry." >&2; exit 1
    fi
elif [ -e "$INSTALL/profiles.json" ]; then
    echo "Profiles were added during preflight. No upgrade performed; retry." >&2; exit 1
fi

if launchctl print "$JOB" >/dev/null 2>&1; then WAS_LOADED=1; fi
if launchctl print-disabled "$DOMAIN" 2>/dev/null | grep -Eq '"com\.edid-override"[[:space:]]*=>[[:space:]]*true'; then WAS_DISABLED=1; fi
BACKUP="$HOME/.config/edid-override-backups/profiles-$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$BACKUP"
if [ -d "$INSTALL" ]; then cp -R "$INSTALL" "$BACKUP/install"; fi
if [ -f "$AGENT" ]; then cp "$AGENT" "$BACKUP/agent.plist"; fi
printf '%s\n' "$WAS_LOADED" > "$BACKUP/was-loaded"
printf '%s\n' "$WAS_DISABLED" > "$BACKUP/was-disabled"
MUTATED=1
launchctl bootout "$JOB" >/dev/null 2>&1 || true
if launchctl print "$JOB" >/dev/null 2>&1; then echo "Old background job remains loaded." >&2; exit 1; fi
# Use exact-payload cleanup; never invoke an old first-external-display reset.
"$BUILD/edid_override" --clear-config "$BUILD/profiles.json"
mkdir -p "$INSTALL" "$(dirname "$AGENT")"
install -m 755 "$BUILD/edid_override" "$INSTALL/edid_override"
install -m 600 "$BUILD/profiles.json" "$INSTALL/profiles.json"
install -m 644 "$ROOT/LICENSE" "$INSTALL/LICENSE"
printf '%s\n' "$BACKUP" > "$INSTALL/profiles-backup-path"
bash "$ROOT/secure-permissions.sh"
"$INSTALL/edid_override" --enable
COMPLETE=1
echo "Multi-profile installation complete. Existing profiles were preserved."
echo "Your previous installation is backed up at: $BACKUP"
echo "List:   ~/.config/edid-override/edid_override --list"
echo "Status: ~/.config/edid-override/edid_override --status"
