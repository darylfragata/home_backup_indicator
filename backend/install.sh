#!/usr/bin/env bash
# Installs the backup script, default config, and systemd --user units, then
# enables the timer. Safe to re-run (won't overwrite an existing config.conf).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin/home-backup-indicator"
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
CONFIG_DIR="$HOME/.config/home-backup-indicator"

mkdir -p "$BIN_DIR" "$SYSTEMD_USER_DIR" "$CONFIG_DIR"

install -m 755 "$SCRIPT_DIR/bin/home-backup.sh" "$BIN_DIR/home-backup.sh"
install -m 644 "$SCRIPT_DIR/systemd/home-backup.service" "$SYSTEMD_USER_DIR/home-backup.service"
install -m 644 "$SCRIPT_DIR/systemd/home-backup.timer" "$SYSTEMD_USER_DIR/home-backup.timer"

if [ ! -f "$CONFIG_DIR/config.conf" ]; then
  cp "$SCRIPT_DIR/config/config.conf.example" "$CONFIG_DIR/config.conf"
  echo "Created default config at $CONFIG_DIR/config.conf (edit it to customize remote name/paths)."
else
  echo "Existing config at $CONFIG_DIR/config.conf left untouched."
fi

systemctl --user daemon-reload
systemctl --user enable --now home-backup.timer

echo
echo "Installed. Timer status:"
systemctl --user list-timers home-backup.timer --no-pager || true
echo
echo "Trigger a sync manually with: systemctl --user start home-backup.service"
echo "Watch it happen with:        journalctl --user -u home-backup.service -f"
