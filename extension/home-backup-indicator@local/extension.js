/*
 * Home Backup Indicator — GNOME Shell extension (45+ ESM API).
 *
 * Purely a viewer/trigger: it reads the JSON status file written by the
 * home_backup_indicator backend script and, for "Sync Now", asks systemd to
 * start the backend's oneshot service. It never runs rclone itself, so the
 * sync logic lives in exactly one place (the backend script).
 */

import GObject from 'gi://GObject';
import GLib from 'gi://GLib';
import Gio from 'gi://Gio';
import St from 'gi://St';

import { Extension } from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';

const POLL_INTERVAL_SECONDS = 5;

const STATUS_FILE = GLib.build_filenamev([
  GLib.get_user_state_dir(),
  'home-backup-indicator',
  'status.json',
]);

const ICON_FOR_STATE = {
  idle: 'emblem-default-symbolic',
  ok: 'emblem-default-symbolic',
  syncing: 'view-refresh-symbolic',
  error: 'dialog-error-symbolic',
  unknown: 'folder-remote-symbolic',
};

function formatTimestamp(iso) {
  if (!iso)
    return 'Never';
  const date = GLib.DateTime.new_from_iso8601(iso, null);
  if (!date)
    return iso;
  return date.to_local().format('%Y-%m-%d %H:%M:%S');
}

const BackupIndicator = GObject.registerClass(
class BackupIndicator extends PanelMenu.Button {
  _init() {
    super._init(0.0, 'Home Backup Indicator', false);

    this._icon = new St.Icon({
      icon_name: ICON_FOR_STATE.unknown,
      style_class: 'system-status-icon',
    });
    this.add_child(this._icon);

    this._statusItem = new PopupMenu.PopupMenuItem('Status: unknown', { reactive: false });
    this.menu.addMenuItem(this._statusItem);

    this._lastSyncItem = new PopupMenu.PopupMenuItem('Last sync: unknown', { reactive: false });
    this.menu.addMenuItem(this._lastSyncItem);

    this._errorItem = new PopupMenu.PopupMenuItem('', { reactive: false });
    this._errorItem.visible = false;
    this.menu.addMenuItem(this._errorItem);

    this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

    this._syncNowItem = new PopupMenu.PopupMenuItem('Sync Now');
    this._syncNowItem.connect('activate', () => this._triggerSync());
    this.menu.addMenuItem(this._syncNowItem);

    this._refresh();
    this._timeoutId = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, POLL_INTERVAL_SECONDS, () => {
      this._refresh();
      return GLib.SOURCE_CONTINUE;
    });
  }

  _readStatus() {
    const file = Gio.File.new_for_path(STATUS_FILE);
    if (!file.query_exists(null))
      return null;

    try {
      const [ok, contents] = file.load_contents(null);
      if (!ok)
        return null;
      return JSON.parse(new TextDecoder('utf-8').decode(contents));
    } catch (e) {
      logError(e, 'home-backup-indicator: failed to read/parse status file');
      return null;
    }
  }

  _refresh() {
    const status = this._readStatus();

    if (!status) {
      this._icon.icon_name = ICON_FOR_STATE.unknown;
      this._statusItem.label.text = 'Status: no data yet (has it run?)';
      this._lastSyncItem.label.text = 'Last sync: never';
      this._errorItem.visible = false;
      return;
    }

    const state = status.state || 'unknown';
    this._icon.icon_name = ICON_FOR_STATE[state] || ICON_FOR_STATE.unknown;
    this._statusItem.label.text = `Status: ${state}`;
    this._lastSyncItem.label.text = `Last sync: ${formatTimestamp(status.last_success)}`;

    if (state === 'error' && status.last_error) {
      this._errorItem.label.text = `Error: ${status.last_error}`;
      this._errorItem.visible = true;
    } else {
      this._errorItem.visible = false;
    }
  }

  _triggerSync() {
    this._statusItem.label.text = 'Status: triggering sync...';
    try {
      const proc = Gio.Subprocess.new(
        ['systemctl', '--user', 'start', 'home-backup.service'],
        Gio.SubprocessFlags.NONE
      );
      proc.wait_check_async(null, (source, res) => {
        try {
          source.wait_check_finish(res);
        } catch (e) {
          logError(e, 'home-backup-indicator: home-backup.service failed to start');
        }
        this._refresh();
      });
    } catch (e) {
      logError(e, 'home-backup-indicator: failed to spawn systemctl');
      this._refresh();
    }
  }

  destroy() {
    if (this._timeoutId) {
      GLib.source_remove(this._timeoutId);
      this._timeoutId = null;
    }
    super.destroy();
  }
});

export default class HomeBackupIndicatorExtension extends Extension {
  enable() {
    this._indicator = new BackupIndicator();
    Main.panel.addToStatusArea(this.uuid, this._indicator);
  }

  disable() {
    this._indicator?.destroy();
    this._indicator = null;
  }
}
