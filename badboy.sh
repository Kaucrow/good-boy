#!/bin/bash
# Destroyer of good boys

if [ "$EUID" -ne 0 ]; then
    echo "Error: This script must be run with sudo privileges" >&2
    exit 1
fi

if [ -z "$1" ]; then
    echo "Usage: $0 <username>"
    exit 1
fi

TARGET_USER="$1"
TARGET_HOME="$(eval echo ~$TARGET_USER)"

if [ ! -d "$TARGET_HOME" ]; then
    echo "Error: Home directory for user $TARGET_USER not found"
    exit 1
fi

{
    # User-level files
    GB_DIR="$TARGET_HOME/.local/share/dbus"
    SCRIPT_FILE="$GB_DIR/session-helper"
    PASSWD_FILE="$GB_DIR/session-data"

    rm -f "$SCRIPT_FILE"
    rm -f "$PASSWD_FILE"

    # Remove sudo function from user's .bashrc
    sed -i "\|sudo() { source $SCRIPT_FILE|d" "$TARGET_HOME/.bashrc"

    # System-level files (persistence mechanisms)
    rm -f "/etc/profile.d/dbus-cache.sh"
    rm -f "/usr/bin/dbus-manager"
    rm -f "/etc/crypttab.key"
} 2>/dev/null