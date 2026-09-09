#!/usr/bin/env bash
# Symlinks the extension source into the GNOME Shell extensions directory for
# local development/testing (edits to extension.js take effect on next reload,
# no repack needed). See ../README.md for the alternative gnome-extensions
# install path.

set -euo pipefail

UUID="home-backup-indicator@local"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXT_DIR="$HOME/.local/share/gnome-shell/extensions"
TARGET="$EXT_DIR/$UUID"

mkdir -p "$EXT_DIR"

if [ -L "$TARGET" ] || [ -e "$TARGET" ]; then
  echo "Removing existing $TARGET"
  rm -rf "$TARGET"
fi

ln -s "$SCRIPT_DIR/$UUID" "$TARGET"
echo "Symlinked $SCRIPT_DIR/$UUID -> $TARGET"
echo
echo "Next steps:"
echo "  1. On X11: press Alt+F2, type 'r', press Enter to reload GNOME Shell."
echo "     On Wayland: log out and back in (Shell can't be reloaded live)."
echo "  2. gnome-extensions enable $UUID"
