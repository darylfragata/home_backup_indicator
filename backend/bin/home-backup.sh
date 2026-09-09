#!/usr/bin/env bash
#
# home-backup.sh — syncs selected folders from $HOME to a cloud remote via rclone.
#
# Distro-independent: only depends on bash, coreutils, and rclone. Reads
# optional user overrides from $XDG_CONFIG_HOME/home-backup-indicator/config.conf
# and reports status/progress to $XDG_STATE_HOME/home-backup-indicator/status.json
# so the GNOME extension (or anything else) can display it without reimplementing
# any sync logic.

set -uo pipefail

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/home-backup-indicator"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/home-backup-indicator"
STATUS_FILE="$STATE_DIR/status.json"
LOG_FILE="$STATE_DIR/backup.log"
STATE_FILE="$STATE_DIR/state.env"
CONFIG_FILE="$CONFIG_DIR/config.conf"
LOCK_FILE="$STATE_DIR/backup.lock"

mkdir -p "$STATE_DIR" "$CONFIG_DIR"

# Prevent overlapping runs (e.g. a slow sync still in progress when the timer fires again).
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") Another sync is already running; exiting." >> "$LOG_FILE"
  exit 0
fi

# ---- Defaults (override any of these in $CONFIG_FILE) ----
RCLONE_REMOTE="onedrive"
REMOTE_BASE="HomeBackup"

# Map of local source path -> subfolder under ${RCLONE_REMOTE}:${REMOTE_BASE}
declare -A SYNC_PATHS=(
  ["$HOME/.ssh"]="ssh"
  ["$HOME/Documents"]="Documents"
  ["$HOME/projects"]="projects"
)

# Individual files synced as a set into ${REMOTE_BASE}/dotfiles
DOTFILES=(
  "$HOME/.bashrc"
  "$HOME/.gitconfig"
)

# rclone filter patterns applied to every folder sync above (not to DOTFILES).
EXCLUDES=(
  --exclude "node_modules/**"
  --exclude ".venv/**"
  --exclude "venv/**"
  --exclude "__pycache__/**"
  --exclude "*.pyc"
  --exclude "dist/**"
  --exclude "build/**"
  --exclude "target/**"
  --exclude ".cache/**"
)

# shellcheck disable=SC1090
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

# ---- Persistent state (survives across runs) ----
LAST_SUCCESS=""
LAST_ERROR=""
LAST_ERROR_TIME=""
# shellcheck disable=SC1090
[ -f "$STATE_FILE" ] && source "$STATE_FILE"

LAST_SYNC_START=""
LAST_SYNC_END=""

log() {
  printf '%s %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$1" >> "$LOG_FILE"
}

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/}"
  printf '%s' "$s"
}

json_str_or_null() {
  if [ -n "$1" ]; then printf '"%s"' "$(json_escape "$1")"; else printf 'null'; fi
}

write_status() {
  local state="$1"
  {
    printf '{\n'
    printf '  "state": %s,\n' "$(json_str_or_null "$state")"
    printf '  "remote": %s,\n' "$(json_str_or_null "${RCLONE_REMOTE}:${REMOTE_BASE}")"
    printf '  "last_sync_start": %s,\n' "$(json_str_or_null "$LAST_SYNC_START")"
    printf '  "last_sync_end": %s,\n' "$(json_str_or_null "$LAST_SYNC_END")"
    printf '  "last_success": %s,\n' "$(json_str_or_null "$LAST_SUCCESS")"
    printf '  "last_error": %s,\n' "$(json_str_or_null "$LAST_ERROR")"
    printf '  "last_error_time": %s\n' "$(json_str_or_null "$LAST_ERROR_TIME")"
    printf '}\n'
  } > "$STATUS_FILE.tmp" && mv "$STATUS_FILE.tmp" "$STATUS_FILE"
}

persist_state() {
  {
    printf 'LAST_SUCCESS=%q\n' "$LAST_SUCCESS"
    printf 'LAST_ERROR=%q\n' "$LAST_ERROR"
    printf 'LAST_ERROR_TIME=%q\n' "$LAST_ERROR_TIME"
  } > "$STATE_FILE"
}

fail() {
  local msg="$1"
  LAST_ERROR="$msg"
  LAST_ERROR_TIME="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  LAST_SYNC_END="$LAST_ERROR_TIME"
  log "ERROR: $msg"
  persist_state
  write_status "error"
  exit 1
}

# ---- Preflight checks: never crash, always leave a clear status ----
if ! command -v rclone >/dev/null 2>&1; then
  fail "rclone is not installed. Install it (e.g. 'sudo dnf install rclone') and re-run."
fi

if ! rclone listremotes 2>/dev/null | grep -qx "${RCLONE_REMOTE}:"; then
  fail "rclone remote '${RCLONE_REMOTE}' is not configured. Run 'rclone config' to set up OneDrive."
fi

# ---- Run sync ----
LAST_SYNC_START="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
write_status "syncing"
log "Starting sync to ${RCLONE_REMOTE}:${REMOTE_BASE}"

SYNC_FAILED=0
SYNC_ERR=""

for src in "${!SYNC_PATHS[@]}"; do
  dest_sub="${SYNC_PATHS[$src]}"
  if [ ! -e "$src" ]; then
    log "SKIP: $src does not exist"
    continue
  fi
  log "Syncing $src -> ${RCLONE_REMOTE}:${REMOTE_BASE}/${dest_sub}"
  if ! rclone sync "$src" "${RCLONE_REMOTE}:${REMOTE_BASE}/${dest_sub}" "${EXCLUDES[@]}" --log-file "$LOG_FILE" --log-level INFO; then
    SYNC_FAILED=1
    SYNC_ERR="Failed syncing $src"
    log "ERROR syncing $src"
  fi
done

if [ "${#DOTFILES[@]}" -gt 0 ]; then
  tmp_dotfiles_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dotfiles_dir"' EXIT
  for f in "${DOTFILES[@]}"; do
    [ -e "$f" ] && cp -a "$f" "$tmp_dotfiles_dir/"
  done
  log "Syncing dotfiles -> ${RCLONE_REMOTE}:${REMOTE_BASE}/dotfiles"
  if ! rclone sync "$tmp_dotfiles_dir" "${RCLONE_REMOTE}:${REMOTE_BASE}/dotfiles" --log-file "$LOG_FILE" --log-level INFO; then
    SYNC_FAILED=1
    SYNC_ERR="Failed syncing dotfiles"
    log "ERROR syncing dotfiles"
  fi
fi

LAST_SYNC_END="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

if [ "$SYNC_FAILED" -ne 0 ]; then
  fail "${SYNC_ERR:-rclone sync failed}. See $LOG_FILE for details."
fi

LAST_SUCCESS="$LAST_SYNC_END"
LAST_ERROR=""
LAST_ERROR_TIME=""
persist_state
write_status "ok"
log "Sync completed successfully"
exit 0
