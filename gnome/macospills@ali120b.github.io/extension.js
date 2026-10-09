/* macOS Caps Pill — GNOME Shell extension (target: GNOME 50/51).
 *
 * Shows a small ⇪ capsule while Caps Lock is ON, placed just below the
 * text caret (or above it when there is no room). Follows the caret as
 * it moves. With a window focused but no caret yet (post-unminimize,
 * pre-first-keystroke) it stays hidden until live typing arms it;
 * on the bare desktop / overview (no focus at all) it hides — there
 * is no caret to point at. Transitional carets from map animations
 * are suppressed, so unminimizing never parks the pill at a weird spot.
 *
 * Layout flash (macOS input-source pill): same capsule, short source
 * label ("US", "ARA"), 1 s on real switches. Unlike caps it needs no
 * key-arming — the switch hotkey is the interaction — and it shows as
 * soon as a text field is focused, even before the first caret rect
 * arrives (IBus focus, not caret, gates it). With a caret it sits at
 * the caret; with focus-but-no-caret yet it uses the monitor fallback.
 * With no text focus at all (desktop, plain window) it stays hidden.
 *
 * Switching: the extension owns Ctrl+Shift+Space in-process and cycles
 * the shell's own InputSourceManager, so the switch is real (Mutter
 * xkb + IBus engine together). The old layout-toggle.sh approach of
 * writing `org.gnome.desktop.input-sources current` cannot work: that
 * key is DEPRECATED and ignored by the shell, and `mru-sources` is
 * written BY the shell after a switch, not read to trigger one.
 *
 * Caps state: kernel LED (/sys/class/leds/*capslock/brightness), polled.
 * Caret: GNOME Shell's own IBus cursor tracking — the same signals the
 * shell's candidate popup uses (js/ui/ibusCandidatePopup.js):
 *   - `set-cursor-location` via IBusManager's public re-emit (X11 clients,
 *     shell entries)
 *   - `set-cursor-location-relative` straight from the shell's panel
 *     service (Wayland clients, which never send absolute coords).
 * No accessibility switch needed.
 *
 * NOTE on `_panelService`: it is the shell's private IBus panel service,
 * not a public API. We (re)hook it whenever IBusManager reports `ready`,
 * so bus restarts are survived. If a future Shell renames it, the pill
 * keeps working in on-screen fallback mode.
 */

import Clutter from 'gi://Clutter';
import Gdk from 'gi://Gdk';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Meta from 'gi://Meta';
import Mtk from 'gi://Mtk';
import Pango from 'gi://Pango';
import Shell from 'gi://Shell';
import St from 'gi://St';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import {getIBusManager} from 'resource:///org/gnome/shell/misc/ibusManager.js';

const PILL_W = 46;
const PILL_H = 30;
const GAP = 6;
const FADE_IN_MS = 90;
const FADE_OUT_MS = 140;
const POLL_MS = 150;
const LAYOUT_HOLD_MS = 1000;
const DEBUG = false;

export default class MacospillsCapsPill extends Extension {
    enable() {
        this._capsOn = false;
        this._wanted = false;
        this._fadeToken = 0;
        this._caret = null; // {x, y, w, h} in stage coords, or null
        // Text-field focus, independent of caret rects: IBus focus-in
        // means "a textbox is selected" even before the first cursor
        // rect arrives (clients usually send that on first caret move,
        // i.e. first keystroke). The layout flash gates on THIS, not
        // on _caret, so Ctrl+Shift+Space flashes immediately like on
        // Hyprland (whose bridge publishes a caret on focus). Caps keeps
        // its strict caret+arming rule — focus alone never shows ⇪.
        this._ibusFocused = false;
        // First-key arming (same rule as Hyprland/KDE): the pill appears
        // only after live typing in the focused field. Focus generation
        // re-arms per field; arrivals (null base) only snapshot.
        this._armed = false;
        this._armBase = null;
        this._suppressUntil = 0; // ignore transitional carets after focus jumps
        this._actorSignals = [];
        this._trackedActor = null;
        this._ledPaths = this._findCapsLeds();
        this._busSignals = [];
        this._psSignals = [];

        this._pill = new St.Bin({
            style_class: 'macospills-caps-pill',
            x_align: Clutter.ActorAlign.CENTER,
            y_align: Clutter.ActorAlign.CENTER,
            opacity: 0,
            visible: false,
            reactive: false,
        });
        const icon = new St.Icon({
            style_class: 'macospills-caps-icon',
            gicon: new Gio.FileIcon({
                file: Gio.File.new_for_path(`${this.path}/caps.svg`),
            }),
            icon_size: 16,
        });
        this._pill.set_child(icon);
        Main.uiGroup.add_child(this._pill);

        // Layout flash (macOS input-source pill): same capsule, short
        // source label ("US", "ARA"). 1 s at the caret on real switches,
        // focus-gated (not caret-gated), no key-arming. Held caps pill
        // wins conflicts.
        this._layoutLabel = new St.Label({
            style_class: 'macospills-layout-label',
        });
        this._layoutPill = new St.Bin({
            style_class: 'macospills-layout-pill',
            x_align: Clutter.ActorAlign.CENTER,
            y_align: Clutter.ActorAlign.CENTER,
            opacity: 0,
            visible: false,
            reactive: false,
        });
        this._layoutPill.set_child(this._layoutLabel);
        Main.uiGroup.add_child(this._layoutPill);
        // Never ellipsize the 2-3 char source id: if theme metrics ever
        // undersize the pill by a pixel, full text with a hair of
        // overflow beats "....". Guarded: harmless no-op if the label
        // internals change.
        try {
            const inner = this._layoutLabel.get_children()[0];
            if (inner && typeof inner.set_ellipsize === 'function')
                inner.set_ellipsize(Pango.EllipsizeMode.NONE);
        } catch {
            // label without a text child; natural sizing still fits
        }
        this._lastLayout = '';
        this._seenLayout = false;
        this._layoutTimerId = 0;
        this._layoutShowing = false;
        this._layoutAllocId = 0;
        // The shell writes mru-sources AFTER every interactive switch
        // (active source first) and emits current-source-changed
        // in-process. Both are real switch signals. The old
        // `changed::current` key is DEPRECATED and ignored — watching
        // it is why the flash never fired.
        try {
            this._layoutSettings = new Gio.Settings({
                schema_id: 'org.gnome.desktop.input-sources',
            });
            this._layoutChangedId = this._layoutSettings.connect(
                'changed::mru-sources', () => this._onLayoutSwitch());
            this._lastLayout = this._currentLayoutShort();
            this._seenLayout = true;
        } catch {
            this._layoutSettings = null;
        }
        // In-process switch signal: instant, covers Super+Space,
        // top-bar clicks, and our own Ctrl+Shift+Space alike.
        this._ismSignalId = 0;
        try {
            const ism = this._getInputSourceManager();
            if (ism)
                this._ismSignalId = ism.connect(
                    'current-source-changed', () => this._onLayoutSwitch());
        } catch {
            // indicator not ready yet; mru-sources watch covers us
        }

        const manager = getIBusManager();
        this._busSignals.push(
            manager.connect('ready', () => this._hookPanelService()));
        this._busSignals.push(
            manager.connect('set-cursor-location', (_m, rect) => {
                // Absolute coords: already stage coords for shell entries,
                // window-relative for X11 clients (same rule as the shell).
                // Desktop (no focus window, no key focus): there is no
                // caret to point at — drop instead of parking at a stale
                // absolute rect.
                const focusWindow = global.display.focus_window;
                if (!focusWindow && !global.stage.key_focus) {
                    this._caret = null;
                    if (this._capsOn)
                        this._hide();
                    return;
                }
                let r = rect;
                if (!global.stage.key_focus && focusWindow)
                    r = this._toStageRect(focusWindow, rect);
                if (r)
                    this._onCaret(r.x, r.y, r.width, r.height, 'abs');
            }));
        this._busSignals.push(
            manager.connect('focus-in', () => {
                // New field focused: the old caret is stale (apps only
                // send a fresh position once the caret moves, usually on
                // the first keystroke) — drop it and wait for the real
                // one instead of sitting at the last spot. But the FIELD
                // is focused now: remember it so a layout switch flashes
                // immediately (Hyprland parity — no keypress needed).
                this._ibusFocused = true;
                this._caret = null;
                this._resetArm();
                this._cancelLayoutFlash();
                if (this._capsOn)
                    this._hide();
            }));
        this._busSignals.push(
            manager.connect('focus-out', () => {
                this._ibusFocused = false;
                this._caret = null;
                this._resetArm();
                this._cancelLayoutFlash();
                this._hide();
            }));
        this._focusWindowId = global.display.connect(
            'notify::focus-window', () => {
                // Focus moved elsewhere (incl. minimize-to-desktop and
                // unminimize): the old caret is stale, and any caret
                // that arrives mid map-animation uses transitional
                // geometry — suppress it and wait for the real one
                // (usually the first keystroke) instead of sitting at
                // a weird spot. Window jumps also drop IME focus
                // optimistically; a real field's focus-in re-sets it.
                this._ibusFocused = false;
                this._caret = null;
                this._resetArm();
                this._cancelLayoutFlash();
                this._suppressUntil = Date.now() + 400;
                this._trackFocusedActor();
                this._updateWant();
            });
        // Clicks move the caret with no keypress (same-surface fields
        // send no focus event): reset arming so the arrival only
        // snapshots — strict first-key rule.
        this._stageClickId = global.stage.connect(
            'button-press-event', () => this._resetArm());
        // Also owns Ctrl+Shift+Space: cycles the shell's input sources
        // in-process (the only path that really switches — gsettings
        // `current` is deprecated/ignored, `mru-sources` is write-only
        // telemetry). Owned as a real wm keybinding (works everywhere,
        // unlike a stage listener which misses client-focused keys).
        // The switch then flashes via current-source-changed.
        // (Kept as a belt-and-braces stage fallback below it.)
        try {
            this._toggleSettings = this._loadToggleSettings();
            if (this._toggleSettings) {
                Main.wm.addKeybinding(
                    'toggle-layout',
                    this._toggleSettings,
                    Meta.KeyBindingFlags.NONE,
                    Shell.ActionMode.ALL,
                    () => this._toggleLayout());
                this._ownsWmBinding = true;
            }
        } catch {
            // keybinding unavailable (schema missing?): the stage
            // fallback below still catches it in most clients
            this._toggleSettings = null;
            this._ownsWmBinding = false;
        }
        this._deleteUntil = 0;
        // Stage fallback for the toggle (the wm keybinding above is
        // primary; this catches clients where it still propagates).
        // Delete branch is the Gecko backspace transient hold (same as
        // the Hyprland bridge): a delete commit can carry a rect jumped
        // the wrong way.
        this._stageKeyId = global.stage.connect(
            'key-press-event', (_a, event) => {
                try {
                    const sym = event.get_key_symbol();
                    if (sym === Gdk.KEY_BackSpace ||
                        sym === Gdk.KEY_Delete ||
                        sym === Gdk.KEY_KP_Delete) {
                        this._deleteUntil = Date.now() + 250;
                        return Clutter.EVENT_PROPAGATE;
                    }
                    if ((sym === Gdk.KEY_space || sym === Gdk.KEY_KP_Space) &&
                        this._ctrlShiftOnly(event)) {
                        this._toggleLayout();
                        return Clutter.EVENT_STOP;
                    }
                } catch {
                    // unreadable key event: no hold
                }
                return Clutter.EVENT_PROPAGATE;
            });
        this._trackFocusedActor();

        this._hookPanelService();

        this._pollId = GLib.timeout_add(
            GLib.PRIORITY_DEFAULT, POLL_MS, () => {
                this._pollCaps();
                return GLib.SOURCE_CONTINUE;
            });
        this._pollCaps();
    }

    disable() {
        if (this._pollId) {
            GLib.source_remove(this._pollId);
            this._pollId = 0;
        }
        if (this._layoutTimerId) {
            GLib.source_remove(this._layoutTimerId);
            this._layoutTimerId = 0;
        }
        this._dropLayoutAlloc();
        if (this._layoutSettings && this._layoutChangedId) {
            try {
                this._layoutSettings.disconnect(this._layoutChangedId);
            } catch {
                // settings gone with the session
            }
        }
        this._layoutSettings = null;
        this._layoutChangedId = 0;
        try {
            const ism = this._getInputSourceManager();
            if (ism && this._ismSignalId)
                ism.disconnect(this._ismSignalId);
        } catch {
            // manager gone with the session
        }
        this._ismSignalId = 0;
        this._ibusFocused = false;
        if (this._ownsWmBinding) {
            try {
                Main.wm.removeKeybinding('toggle-layout');
            } catch {
                // binding already gone with the session
            }
            this._ownsWmBinding = false;
        }
        this._toggleSettings = null;
        const manager = getIBusManager();
        for (const id of this._busSignals)
            manager.disconnect(id);
        this._busSignals = [];
        this._unhookPanelService();
        this._untrackFocusedActor();
        if (this._focusWindowId) {
            global.display.disconnect(this._focusWindowId);
            this._focusWindowId = 0;
        }
        if (this._stageClickId) {
            try {
                global.stage.disconnect(this._stageClickId);
            } catch {
                // stage gone with the session
            }
            this._stageClickId = 0;
        }
        if (this._stageKeyId) {
            try {
                global.stage.disconnect(this._stageKeyId);
            } catch {
                // stage gone with the session
            }
            this._stageKeyId = 0;
        }
        this._pill?.destroy();
        this._pill = null;
        this._layoutPill?.destroy();
        this._layoutPill = null;
        this._layoutLabel = null;
        this._caret = null;
    }

    // --- caps state ---------------------------------------------------

    _findCapsLeds() {
        const paths = [];
        try {
            const dir = Gio.File.new_for_path('/sys/class/leds');
            const en = dir.enumerate_children(
                'standard::name', Gio.FileQueryInfoFlags.NONE, null);
            let info;
            while ((info = en.next_file(null)) !== null) {
                const name = info.get_name();
                if (name.includes('capslock'))
                    paths.push(`/sys/class/leds/${name}/brightness`);
            }
        } catch {
            // No LED (VM?): pill stays hidden, IPC-less by design.
        }
        return paths;
    }

    _pollCaps() {
        let on = false;
        for (const p of this._ledPaths) {
            try {
                const [ok, bytes] = GLib.file_get_contents(p);
                if (ok && Number(new TextDecoder().decode(bytes).trim()) === 1) {
                    on = true;
                    break;
                }
            } catch {
                // read raced with device removal; next tick retries
            }
        }
        this._setCaps(on);
        // Reconciler (see _updateWant): heals any missed event.
        this._updateWant();
    }

    _setCaps(on) {
        if (on === this._capsOn)
            return;
        this._capsOn = on;
        if (on) {
            // Preempt any layout flash. Strict first-key rule: the
            // toggle arms nothing — first keypress arms.
            this._cancelLayoutFlash();
            this._resetArm();
            this._show();
        } else {
            this._hide();
        }
    }

    _resetArm() {
        this._armed = false;
        this._armBase = null;
    }

    _cancelLayoutFlash() {
        if (this._layoutTimerId) {
            GLib.source_remove(this._layoutTimerId);
            this._layoutTimerId = 0;
        }
        this._dropLayoutAlloc();
        this._layoutShowing = false;
        this._layoutPill?.hide();
    }

    _dropLayoutAlloc() {
        if (this._layoutAllocId && this._layoutPill) {
            try {
                this._layoutPill.disconnect(this._layoutAllocId);
            } catch {
                // pill already destroyed with the session
            }
        }
        this._layoutAllocId = 0;
    }

    // One-line caret/flash diagnostics for per-app misbehavior
    // (e.g. Alacritty): only written while a layout flash is live, so
    // the file stays tiny. Ring buffer, newest last.
    _traceCaret(src, x, y, w, h, note) {
        try {
            if (!this._layoutShowing && note !== 'flash')
                return;
            if (!this._traceLines)
                this._traceLines = [];
            const r = (v) => Math.round(v);
            this._traceLines.push(
                `${Date.now()} ${src} caret=${r(x)},${r(y)} ${r(w)}x${r(h)} ${note}`);
            while (this._traceLines.length > 200)
                this._traceLines.shift();
            GLib.file_set_contents('/tmp/macospills-caret.log',
                this._traceLines.join('\n') + '\n');
        } catch {
            // diagnostics never break the pill
        }
    }

    // --- caret tracking (mirrors 51.0 ibusCandidatePopup.js) -----------

    _hookPanelService() {
        this._unhookPanelService();
        let ps = null;
        try {
            ps = getIBusManager()._panelService;
        } catch {
            ps = null;
        }
        if (!ps)
            return;
        this._panelService = ps;
        try {
            this._psSignals.push(ps.connect(
                'set-cursor-location-relative', (_p, x, y, w, h) => {
                    const focusWindow = global.display.focus_window;
                    if (!focusWindow)
                        return;
                    // Unmapped/transitional actor (unminimize animation):
                    // geometry is garbage — suppress like the absolute path
                    try {
                        const a = focusWindow.get_compositor_private();
                        if (a && !a.mapped)
                            return;
                    } catch {
                        // actor gone; drop below
                    }
                    const rect = this._toStageRectRelative(
                        focusWindow, {x, y, width: w, height: h});
                    if (rect)
                        this._onCaret(rect.x, rect.y, rect.width, rect.height, 'rel');
                }));
        } catch {
            // Old IBus without the relative signal: absolute still covers
            // X11 clients and shell entries; Wayland falls back on-screen.
        }
    }

    // Follow the focused window while visible: a move/resize (tiling,
    // unminimize settle) with a known caret re-places the pill instead
    // of leaving it at the transitional spot.
    _trackFocusedActor() {
        this._untrackFocusedActor();
        try {
            const w = global.display.focus_window;
            const a = w?.get_compositor_private();
            if (!a)
                return;
            this._trackedActor = a;
            this._actorSignals.push(a.connect('position-changed', () => {
                if (this._capsOn && this._caret)
                    this._place();
            }));
            this._actorSignals.push(a.connect('size-changed', () => {
                if (this._capsOn && this._caret)
                    this._place();
            }));
        } catch {
            // actor without signals (overview): nothing to follow
        }
    }

    _untrackFocusedActor() {
        if (this._trackedActor) {
            for (const id of this._actorSignals) {
                try {
                    this._trackedActor.disconnect(id);
                } catch {
                    // actor already destroyed with its window
                }
            }
        }
        this._actorSignals = [];
        this._trackedActor = null;
    }

    _unhookPanelService() {
        if (this._panelService && this._psSignals.length) {
            for (const id of this._psSignals) {
                try {
                    this._panelService.disconnect(id);
                } catch {
                    // service died with the bus; nothing to disconnect
                }
            }
        }
        this._psSignals = [];
        this._panelService = null;
    }

    _toStageRect(focusWindow, rect) {
        try {
            const r = new Mtk.Rectangle({
                x: rect.x, y: rect.y, width: rect.width, height: rect.height,
            });
            return focusWindow.protocol_to_stage_rect(r);
        } catch {
            return null;
        }
    }

    _toStageRectRelative(focusWindow, rect) {
        try {
            let r = new Mtk.Rectangle({
                x: rect.x, y: rect.y, width: rect.width, height: rect.height,
            });
            r = focusWindow.protocol_to_stage_rect(r);
            const actor = focusWindow.get_compositor_private();
            // IBus GtkIMModule cannot see the shell scale.
            const scale = actor.get_resource_scale();
            return {
                x: actor.x + r.x / scale,
                y: actor.y + r.y / scale,
                width: r.width / scale,
                height: r.height / scale,
            };
        } catch {
            return null;
        }
    }

    _onCaret(x, y, w, h, src = '') {
        if (w <= 0 && h <= 0) {
            // Degenerate rect (field blurred/emptied): no caret to
            // point at — hide instead of parking top-left.
            this._traceCaret(src, x, y, w, h, 'drop-degenerate');
            this._caret = null;
            this._resetArm();
            if (this._capsOn)
                this._hide();
            return;
        }
        // Transitional geometry (unminimize map animation, window drag):
        // the app sends a caret against the old actor position. Ignore
        // it for 400 ms after a focus jump — the fresh caret (usually
        // the first keystroke) replaces it. Without this the pill sits
        // at a weird spot until typing.
        if (Date.now() < this._suppressUntil) {
            if (DEBUG)
                log(`macospills: suppressed transitional caret ${x},${y}`);
            this._traceCaret(src, x, y, w, h, 'drop-suppressed');
            return;
        }
        // Sanity: must be finite, sane-sized, and near a monitor.
        // A stale rect from a moved/minimized window fails here and the
        // pill hides instead of teleporting.
        if (!Number.isFinite(x) || !Number.isFinite(y) ||
            w > 200 || h > 200 || w < 0 || h < 0) {
            this._traceCaret(src, x, y, w, h, 'drop-insane');
            this._caret = null;
            if (this._capsOn)
                this._hide();
            return;
        }
        const m = this._monitorFor(x + w / 2, y);
        const M = 64;
        if (x + w / 2 < m.x - M || x + w / 2 > m.x + m.width + M ||
            y < m.y - M || y > m.y + m.height + M) {
            this._traceCaret(src, x, y, w, h, 'drop-offscreen');
            this._caret = null;
            if (this._capsOn)
                this._hide();
            return;
        }
        // Delete transient hold: inside a delete window a same-line
        // rightward jump contradicts the key — hold the old caret for
        // this update instead of jumping wrong. Next commit confirms.
        if (this._caret && Date.now() < this._deleteUntil && y === this._caret.y &&
            x > this._caret.x + 2) {
            if (DEBUG)
                log(`macospills: held delete transient ${x},${y}`);
            this._traceCaret(src, x, y, w, h, 'drop-deletehold');
            return;
        }
        this._caret = {x, y, w, h};
        if (this._layoutShowing) {
            this._placeLayout();
            this._traceCaret(src, x, y, w, h,
                `follow pill=${Math.round(this._layoutPill.x)},${Math.round(this._layoutPill.y)}`);
        }
        if (this._capsOn) {
            // First-key arming: a rect->rect move with a caret up arms;
            // arrivals (null base) only snapshot. Same-focus typing
            // always arms; focus jumps re-baselined above never do.
            if (!this._armBase) {
                this._armBase = this._caret;
            } else if (x !== this._armBase.x || y !== this._armBase.y ||
                       w !== this._armBase.w || h !== this._armBase.h) {
                this._armed = true;
                this._armBase = this._caret;
            }
            this._show();
        }
    }

    // --- layout flash -------------------------------------------------

    _shortSourceId(id) {
        const base = String(id).split('+')[0].toUpperCase();
        return base.slice(0, 6) || '?';
    }

    // Live InputSourceManager without importing its (private-path)
    // module: the panel keyboard indicator already holds the singleton.
    _getInputSourceManager() {
        try {
            const kb = Main.panel?.statusArea?.keyboard;
            if (kb?._inputSourceManager)
                return kb._inputSourceManager;
        } catch {
            // panel not ready; caller falls back to gsettings
        }
        return null;
    }

    // Bundled toggle-layout schema, loaded from the extension dir so no
    // system install step is needed. Falls back to the default
    // ['<Primary><Shift>space'] when the schema file is missing.
    _loadToggleSettings() {
        const SCHEMA_ID = 'org.gnome.shell.extensions.macospills';
        try {
            const dir = Gio.File.new_for_path(`${this.path}/schemas`);
            if (dir.query_exists(null)) {
                const src = Gio.SettingsSchemaSource.new_from_directory(
                    `${this.path}/schemas`,
                    Gio.SettingsSchemaSource.get_default(),
                    false);
                const schema = src.lookup(SCHEMA_ID, false);
                if (schema)
                    return new Gio.Settings({settings_schema: schema});
            }
        } catch {
            // fall through to system-installed schema
        }
        try {
            return new Gio.Settings({schema_id: SCHEMA_ID});
        } catch {
            return null;
        }
    }

    _currentLayoutShort() {
        // Prefer the live manager: its currentSource is authoritative
        // the moment a switch lands. Fall back to gsettings mru[0],
        // which the shell maintains active-first after every switch.
        // (`current` is DEPRECATED and ignored — never read it.)
        try {
            const ism = this._getInputSourceManager();
            const cur = ism?.currentSource;
            if (cur?.shortName)
                return String(cur.shortName).toUpperCase().slice(0, 6) || '?';
        } catch {
            // manager not ready; try gsettings below
        }
        try {
            const st = this._layoutSettings;
            const mru = st.get_value('mru-sources').deep_unpack();
            if (mru.length)
                return this._shortSourceId(mru[0][1]);
            const sources = st.get_value('sources').deep_unpack();
            if (sources.length)
                return this._shortSourceId(sources[0][1]);
        } catch {
            // schema without sources (locked-down session)
        }
        return '';
    }

    // "Is a textbox selected?" — IBus focus OR a live caret OR a shell
    // text entry. Deliberately weaker than the caps pill's caret+arming
    // rule: the switch hotkey IS the interaction, so no keypress needed
    // (Hyprland parity: its bridge has a caret on focus already).
    _isShellEntryFocused() {
        try {
            const kf = global.stage.key_focus;
            if (!kf)
                return false;
            if (kf instanceof Clutter.Text)
                return true;
            if (typeof kf.get_clutter_text === 'function')
                return true;
        } catch {
            // stage gone; treat as unfocused
        }
        return false;
    }

    _hasTextFocus() {
        return this._ibusFocused || !!this._caret ||
            this._isShellEntryFocused();
    }

    _ctrlShiftOnly(event) {
        // Ctrl+Shift held, Alt/Super NOT held. Caps/Num lock ignored.
        try {
            const state = event.get_state();
            const want = Gdk.ModifierType.CONTROL_MASK |
                Gdk.ModifierType.SHIFT_MASK;
            if ((state & want) !== want)
                return false;
            const ban = Gdk.ModifierType.MOD1_MASK |
                Gdk.ModifierType.MOD4_MASK;
            return (state & ban) === 0;
        } catch {
            return false;
        }
    }

    _toggleLayout() {
        // Real switch via the shell's own manager (Mutter xkb + IBus
        // engine together). The flash itself comes back through
        // current-source-changed/mru-sources, so no direct flash here
        // (avoids double-flash; the signal path is idempotent anyway).
        let ism = null;
        try {
            ism = this._getInputSourceManager();
        } catch {
            ism = null;
        }
        if (!ism)
            return;
        try {
            const keys = Object.keys(ism.inputSources ?? {})
                .map(Number).sort((a, b) => a - b);
            if (keys.length < 2)
                return;
            const curIdx = ism.currentSource?.index ?? keys[0];
            const at = keys.indexOf(curIdx);
            const next = ism.inputSources[
                keys[(at < 0 ? 0 : at + 1) % keys.length]];
            if (next)
                next.activate(true);
        } catch {
            // keep the hotkey total: a failed switch never shows a pill
        }
    }

    _onLayoutSwitch() {
        const id = this._currentLayoutShort();
        if (!this._seenLayout) {
            this._seenLayout = true;
            this._lastLayout = id;
            return;
        }
        if (!id || id === this._lastLayout)
            return;
        this._lastLayout = id;
        // Focus-gated (not caret-gated): a selected textbox is enough,
        // even pre-first-keystroke when no rect has arrived yet. With
        // no text focus at all (desktop / plain window) stay hidden.
        // Preempts a showing caps pill; the timer hands back to it.
        if (!this._hasTextFocus())
            return;
        this._layoutLabel.set_text(id);
        // Natural size, never hand-sized: the Bin fits the label plus
        // its CSS padding, so the text can never clip to "...". (A
        // measured-then-assigned width goes stale — the label's layout
        // lags set_text on a hidden actor — and alternating US<->ARA
        // then clips every other flash.) Placement below uses an
        // estimate and re-snaps once allocated.
        this._layoutPill.width = -1;
        this._layoutShowing = true;
        this._updateWant();
        this._traceCaret('flash', 0, 0, 0, 0,
            `flash id=${id} caret=${this._caret ? 'yes' : 'no'} focused=${this._ibusFocused}`);
        this._placeLayout();
        this._layoutPill.visible = true;
        this._layoutPill.remove_all_transitions();
        this._layoutPill.ease({
            opacity: 255,
            duration: FADE_IN_MS,
            mode: Clutter.AnimationMode.EASE_OUT_CUBIC,
        });
        // Re-snap once allocated: the pre-show width is an estimate,
        // the allocated box is exact. One-shot, disconnected on hide.
        this._dropLayoutAlloc();
        try {
            this._layoutAllocId = this._layoutPill.connect(
                'notify::allocation', () => {
                    if (this._layoutShowing)
                        this._placeLayout();
                });
        } catch {
            this._layoutAllocId = 0;
        }
        if (this._layoutTimerId)
            GLib.source_remove(this._layoutTimerId);
        this._layoutTimerId = GLib.timeout_add(
            GLib.PRIORITY_DEFAULT, LAYOUT_HOLD_MS, () => {
                this._layoutTimerId = 0;
                this._layoutShowing = false;
                this._dropLayoutAlloc();
                this._layoutPill.ease({
                    opacity: 0,
                    duration: FADE_OUT_MS,
                    mode: Clutter.AnimationMode.EASE_OUT_CUBIC,
                    onComplete: () => this._layoutPill?.hide(),
                });
                this._updateWant();
                return GLib.SOURCE_REMOVE;
            });
    }

    _placeLayout() {
        // Sizing is natural (Bin fits content, see _onLayoutSwitch), so
        // this only centers: prefer the live allocated width, estimate
        // generously pre-show. The allocation handler re-snaps after.
        let w = Math.max(PILL_W,
            (this._layoutLabel.get_text() || '').length * 12 + 24);
        try {
            if (this._layoutPill.visible) {
                const aw = this._layoutPill.width;
                if (aw > 0)
                    w = aw;
            }
        } catch {
            // actor gone; estimate stands
        }
        // Caret path: exactly like the caps pill (below, 6 px gap).
        const c = this._caret;
        if (c) {
            const mon = this._monitorFor(c.x + c.w / 2, c.y);
            let x = Math.round(c.x + c.w / 2 - w / 2);
            let y = Math.round(c.y + c.h + GAP);
            if (y + PILL_H > mon.y + mon.height)
                y = Math.round(c.y - GAP - PILL_H);
            x = Math.max(mon.x, Math.min(mon.x + mon.width - w, x));
            y = Math.max(mon.y, Math.min(mon.y + mon.height - PILL_H, y));
            // Direct set, no glide: every caret commit re-targets, and
            // re-targeting a 60 ms ease on dense updaters (Alacritty)
            // rubber-bands forever — the pill lags or sits. Exact
            // tracking is smooth at caret granularity; fades keep polish.
            this._layoutPill.set_position(x, y);
            return;
        }
        // Focus-but-no-caret-yet (pre-first-keystroke): monitor fallback
        // at 92% height, centered — only reachable when a textbox IS
        // focused (caller gates), so rule 2 still holds.
        const monitors = Main.layoutManager.monitors;
        const mon = monitors[global.display.get_current_monitor()] ??
            monitors[0];
        if (!mon)
            return;
        const x = Math.round(mon.x + mon.width / 2 - w / 2);
        const y = Math.round(mon.y + mon.height * 0.92 - PILL_H / 2);
        this._layoutPill.set_position(
            Math.max(mon.x, Math.min(mon.x + mon.width - w, x)),
            Math.max(mon.y, Math.min(mon.y + mon.height - PILL_H, y)));
    }

    // --- placement + fades --------------------------------------------

    _monitorFor(x, y) {
        const monitors = Main.layoutManager.monitors;
        const cur = monitors[global.display.get_current_monitor()] ?? monitors[0];
        for (const m of monitors) {
            if (x >= m.x && x < m.x + m.width && y >= m.y && y < m.y + m.height)
                return m;
        }
        return cur;
    }

    _place() {
        // Caret required (callers with none hide right after via
        // _updateWant); never throw on null into signal handlers.
        if (!this._caret)
            return;
        const c = this._caret;
        const mon = this._monitorFor(c.x + c.w / 2, c.y);
        let x = Math.round(c.x + c.w / 2 - PILL_W / 2);
        let y = Math.round(c.y + c.h + GAP);
        if (y + PILL_H > mon.y + mon.height)
            y = Math.round(c.y - GAP - PILL_H);
        x = Math.max(mon.x, Math.min(mon.x + mon.width - PILL_W, x));
        y = Math.max(mon.y, Math.min(mon.y + mon.height - PILL_H, y));
        // Direct set, no glide (same reason as _placeLayout): dense
        // caret commits must track exactly, never rubber-band.
        this._pill.set_position(x, y);
    }

    // Visibility is a state machine, not event soup: every event only
    // updates state and calls _updateWant(), and the 150 ms poll
    // reconciles, so no missed event can wedge the pill on or off.
    // First-key rule: wanted needs a known caret AND live typing
    // (_armed). No caret fallback — a pill with nowhere to point is
    // worse than none. A flashing layout pill suppresses caps for its
    // second (hands back on expiry).
    _updateWant() {
        this._setWanted(this._capsOn && this._armed && !!this._caret &&
            !this._layoutShowing);
    }

    _setWanted(want) {
        if (want === this._wanted)
            return;
        this._wanted = want;
        const token = ++this._fadeToken;
        this._pill.remove_all_transitions();
        if (want) {
            this._place();
            this._pill.visible = true;
            this._pill.ease({
                opacity: 255,
                duration: FADE_IN_MS,
                mode: Clutter.AnimationMode.EASE_OUT_CUBIC,
            });
        } else {
            this._pill.ease({
                opacity: 0,
                duration: FADE_OUT_MS,
                mode: Clutter.AnimationMode.EASE_OUT_CUBIC,
                onComplete: () => {
                    if (token === this._fadeToken && !this._wanted)
                        this._pill.hide();
                },
            });
        }
    }

    _show() {
        this._place();
        this._updateWant();
    }

    _hide() {
        this._updateWant();
    }
}
