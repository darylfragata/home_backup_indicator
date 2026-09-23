# home_backup_indicator

Personal backup system: an rclone-based backend that syncs selected folders
from `$HOME` to OneDrive on a systemd timer, and a GNOME Shell top-bar
extension that shows sync status and lets you trigger a sync manually.

The two parts are **loosely coupled by design**: the extension only reads a
status file written by the backend script and (for "Sync Now") asks systemd
to start the backend's service. It never runs rclone itself and has no sync
logic of its own.

## Compatibility

- **Backend** (`backend/`): plain bash + coreutils + `rclone`, driven by
  `systemd --user`. Distro-independent — it targets `$HOME` (never `/home`
  directly), uses `$XDG_STATE_HOME` / `$XDG_CONFIG_HOME` with sane fallbacks,
  and the systemd units use the `%h` specifier instead of a hardcoded path.
  Should work unmodified on any systemd-based Linux distro with `rclone`
  installed.
- **Frontend** (`extension/`): GNOME Shell extension using the ESM-based
  extension API introduced in **GNOME Shell 45**. Targets GNOME Shell 45+ and
  should run on any distro at that version or newer. Built and tested on
  **Fedora Linux 44, GNOME Shell 50.4**.
- Personal use only — not intended for publishing to extensions.gnome.org
  (UUID `home-backup-indicator@local` is not a real reverse-DNS domain,
  which is fine for local-only use but would need changing before publishing).

## Layout

```
backend/
  bin/home-backup.sh          # the sync script (all sync logic lives here)
  config/config.conf.example  # copy to ~/.config/home-backup-indicator/config.conf
  systemd/home-backup.service # oneshot unit that runs the script
  systemd/home-backup.timer   # timer unit (default: every 30 min)
  install.sh                  # installs script+config+units, enables the timer
extension/
  home-backup-indicator@local/
    metadata.json
    extension.js               # reads status.json, triggers the systemd service
  install.sh                    # symlinks the extension for local dev/testing
```

## Backend: what it does

`home-backup.sh`:

1. Checks `rclone` is installed and that the configured remote (default:
   `onedrive`) is set up via `rclone listremotes`. If either check fails, it
   writes a clear error to the status file and log, and **exits cleanly
   instead of crashing**.
2. Picks a destination folder on the remote, `${REMOTE_BASE}`, defaulting to
   `<OS name>Backup` (e.g. `FedoraBackup`, `UbuntuBackup`) derived from
   `/etc/os-release` — so if you run this on more than one machine against
   the same OneDrive account, each one backs up into its own folder instead
   of colliding.
3. Auto-discovers every non-hidden top-level folder in `$HOME` — skipping
   `Downloads`, `Desktop`, `Music`, `Pictures`, `Videos`, `Public`, and
   `Templates` by default — plus `~/.ssh` explicitly, and syncs each one-way
   (local → remote) with `rclone sync`. A default exclude list
   (`node_modules`, `.venv`, `__pycache__`, build/dist/target dirs, `.cache`,
   `.terraform`) keeps large, regeneratable directories out of OneDrive.
   Because the folder list is rebuilt fresh on every run, a newly created
   folder under `$HOME` gets backed up automatically — no config changes
   needed.
4. Copies `DOTFILES` (default: `~/.bashrc`, `~/.gitconfig`) into a temp
   staging dir and syncs that as a set into `${REMOTE_BASE}/dotfiles` on the
   remote.
5. Writes progress/results to two places:
   - `~/.local/state/home-backup-indicator/status.json` — machine-readable
     status for the extension (`state`, `last_success`, `last_error`, etc.)
   - `~/.local/state/home-backup-indicator/backup.log` — human-readable log
     (also fed rclone's own `--log-file` output)
6. Uses an `flock` lock file so an overrunning sync can't overlap with the
   next timer tick.

All folder paths, the remote name, and excludes are overridable in
`~/.config/home-backup-indicator/config.conf` without touching the script —
see the comments in `backend/config/config.conf.example`.

### ⚠️ Note on `~/.ssh`

OneDrive (and rclone's onedrive backend) doesn't preserve Unix file
permissions. If you ever restore `~/.ssh` from the backup, re-run
`chmod 600 ~/.ssh/id_*` (and `chmod 700 ~/.ssh`) afterward, or SSH will
refuse to use the keys. Storing private keys in cloud storage at all is a
tradeoff — this is done here because you explicitly asked for it, but
consider it a soft spot if `~/.ssh` contains keys you're not comfortable
having in OneDrive's storage/retention model.

## Setup

### 1. Install rclone

```bash
sudo dnf install -y rclone     # Fedora; use your distro's package manager elsewhere
rclone version                 # sanity check — this project was built against v1.74.x
```

### 2. Configure the OneDrive remote (one-time, interactive)

```bash
rclone config
```

Walk through the prompts like this:

| Prompt | Answer |
|---|---|
| `n) New remote` | `n` |
| `name>` | `onedrive` (must match `RCLONE_REMOTE` in the backend, default is `onedrive`) |
| `Storage>` | search/select **Microsoft OneDrive** (`onedrive`) from the list |
| `client_id>` / `client_secret>` | leave blank (press Enter) to use rclone's default app |
| `region>` | `1` (Microsoft Cloud Global) unless you're on a special region |
| `Edit advanced config?` | `n` |
| `Use auto config?` | `y` on a desktop with a browser — it opens a browser window for you to sign in and grant access. Answer `n` only if this is a headless machine (it'll give you a link + local server flow instead) |
| Account/drive type | **OneDrive Personal** (or Business/SharePoint if that's your account) |
| `Choose a number from below, or type in your own value` (drive selection) | pick your personal drive from the list |
| `y) Yes this is OK` | `y` |
| `q) Quit config` | `q` |

Then verify it worked:

```bash
rclone listremotes              # should print: onedrive:
rclone about onedrive:          # shows total/used/free space, confirms auth works
```

If you name the remote something other than `onedrive`, copy
`backend/config/config.conf.example` to
`~/.config/home-backup-indicator/config.conf` and set
`RCLONE_REMOTE="yourname"` there instead of editing the script.

### 3. Install the backend (systemd --user service + timer)

```bash
./backend/install.sh
```

This installs the script to `~/.local/bin/home-backup-indicator/`, the units
to `~/.config/systemd/user/`, a default config to
`~/.config/home-backup-indicator/config.conf` (if you don't already have
one), then runs `systemctl --user enable --now home-backup.timer`.

Default cadence is **every 30 minutes** (plus a 5-minute delay after
login/boot). To change it without editing the shipped unit file:

```bash
systemctl --user edit home-backup.timer
```

Add:

```ini
[Timer]
OnUnitActiveSec=2h
```

Then:

```bash
systemctl --user daemon-reload
systemctl --user restart home-backup.timer
```

Useful commands:

```bash
systemctl --user start home-backup.service     # trigger a sync right now
journalctl --user -u home-backup.service -f    # watch it run
systemctl --user list-timers home-backup.timer # see next scheduled run
cat ~/.local/state/home-backup-indicator/status.json
tail -f ~/.local/state/home-backup-indicator/backup.log
```

### 4. Install the GNOME extension (local testing)

Two options:

**Option A — symlink for development (recommended while iterating):**

```bash
./extension/install.sh
```

This symlinks `extension/home-backup-indicator@local/` into
`~/.local/share/gnome-shell/extensions/`, so edits to `extension.js` take
effect on the next Shell reload — no repacking needed.

Then:

- **X11**: `Alt+F2`, type `r`, `Enter` to reload GNOME Shell.
- **Wayland**: log out and back in (Shell can't reload live on Wayland).

Enable it:

```bash
gnome-extensions enable home-backup-indicator@local
```

Or toggle it on via the **Extensions** app (`gnome-extensions-app`), which
also has a built-in log viewer if something goes wrong.

**Option B — proper package install via `gnome-extensions install`:**

```bash
cd extension/home-backup-indicator@local
gnome-extensions pack --force --out-dir=/tmp .
gnome-extensions install --force /tmp/home-backup-indicator@local.shell-extension.zip
gnome-extensions enable home-backup-indicator@local
```

Log out/in (or Alt+F2 r on X11) to load it, same as above.

### Debugging the extension

```bash
journalctl --user -f -o cat /usr/bin/gnome-shell
```

or, more precisely, filter for this extension:

```bash
journalctl --user -f -o cat | grep -i home-backup-indicator
```

`logError()` calls in `extension.js` show up there.

## Verifying your setup

Quick end-to-end check after installing both halves:

```bash
rclone listremotes                                 # onedrive:
rclone about onedrive:                              # confirms auth still works, shows quota
systemctl --user is-active home-backup.timer        # active
systemctl --user list-timers home-backup.timer      # shows next scheduled run
cat ~/.local/state/home-backup-indicator/status.json # state should be "ok" after a run
gnome-extensions list --enabled | grep home-backup   # should list home-backup-indicator@local
```

If `gnome-extensions list --enabled` doesn't show it even after running
`./extension/install.sh`, GNOME Shell hasn't picked up the new symlink yet —
this happens if you install it without reloading first. Reload the Shell
(`Alt+F2 r Enter` on X11, or log out/in on Wayland — GNOME 50 defaults to
Wayland, so log out/in is the reliable path), then run
`gnome-extensions enable home-backup-indicator@local` again and check the
top bar.

## What the extension shows

- **Top-bar icon**: default/checkmark icon when idle or after a successful
  sync, refresh icon while syncing, error icon after a failed sync.
- **Dropdown menu**: current status, last successful sync timestamp, the
  last error message (only shown when the last run failed), a separator,
  a **Sync Now** item, and a **Log in / Re-login OneDrive** item.
- **Sync Now** runs `systemctl --user start home-backup.service` — the
  extension doesn't touch rclone directly, so this is the same code path the
  timer uses. The menu re-reads `status.json` every 5 seconds, so the icon
  and menu update automatically once the backend finishes.

- **Log in / Re-login OneDrive** opens a terminal (Ptyxis, GNOME Terminal,
  Console, Konsole or xterm, first one found) and runs
  `rclone config reconnect <remote>:` to redo the browser sign-in. If the
  remote isn't configured yet it runs `rclone config` instead. The remote
  name comes from `RCLONE_REMOTE` in `config.conf` (default `onedrive`). It
  runs in a terminal because rclone's OAuth flow asks interactive questions.

## Design notes / why it's split this way

- The backend has zero GNOME dependencies and zero knowledge of the
  extension — you could delete the extension entirely and still have a
  working backup system driven by `systemctl` / cron / a terminal.
- The extension has zero rclone/backup logic — it's a thin status viewer and
  a trigger button. If you ever change how syncing works (different backend,
  additional folders, a different cloud provider), the extension needs no
  changes as long as it keeps writing to the same `status.json` schema.
- `status.json` fields: `state` (`syncing` | `ok` | `error`), `remote`,
  `last_sync_start`, `last_sync_end`, `last_success`, `last_error`,
  `last_error_time` — all ISO 8601 UTC timestamps or `null`.
