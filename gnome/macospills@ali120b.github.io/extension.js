/* macOS Caps Pill — GNOME Shell extension (target: GNOME 51).
 *
 * Shows a small ⇪ capsule while Caps Lock is ON, placed just below the
 * text caret (or above it when there is no room). Follows the caret as
 * it moves. With a window focused but no caret yet (post-unminimize,
 * pre-first-keystroke) it shows the bottom-center fallback briefly;
 * on the bare desktop / overview (no focus at all) it hides — there
 * is no caret to point at. Transitional carets from map animations
 * are suppressed, so unminimizing never parks the pill at a weird spot.
 *
 * Caps state: kernel LED (/sys/class/leds/*capslock/brightness), polled.
 * Caret: GNOME Shell's own IBus cursor tracking — the same signals the
 * shell's candidate popup uses (js/ui/ibusCandidatePopup.js in 51.0):
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
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Mtk from 'gi://Mtk';
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
        // caret required, held caps pill wins conflicts.
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
        this._lastLayout = '';
        this._seenLayout = false;
        this._layoutTimerId = 0;
        this._layoutShowing = false;
        try {
            this._layoutSettings = new Gio.Settings({
                schema_id: 'org.gnome.desktop.input-sources',
            });
            this._layoutChangedId = this._layoutSettings.connect(
                'changed::current', () => this._onLayoutSwitch());
            this._lastLayout = this._currentLayoutShort();
            this._seenLayout = true;
        } catch {
            this._layoutSettings = null;
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
                    this._onCaret(r.x, r.y, r.width, r.height);
            }));
        this._busSignals.push(
            manager.connect('focus-in', () => {
                // New field focused: the old caret is stale (apps only
                // send a fresh position once the caret moves, usually on
                // the first keystroke) — drop it and wait for the real
                // one instead of sitting at the last spot.
                this._caret = null;
                this._resetArm();
                this._cancelLayoutFlash();
                if (this._capsOn)
                    this._hide();
            }));
        this._busSignals.push(
            manager.connect('focus-out', () => {
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
                // a weird spot.
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
        if (this._layoutSettings && this._layoutChangedId) {
            try {
                this._layoutSettings.disconnect(this._layoutChangedId);
            } catch {
                // settings gone with the session
            }
        }
        this._layoutSettings = null;
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
        this._layoutShowing = false;
        this._layoutPill?.hide();
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
                        this._onCaret(rect.x, rect.y, rect.width, rect.height);
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

    _onCaret(x, y, w, h) {
        if (w <= 0 && h <= 0) {
            // Degenerate rect (field blurred/emptied): no caret to
            // point at — hide instead of parking top-left.
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
            return;
        }
        // Sanity: must be finite, sane-sized, and near a monitor.
        // A stale rect from a moved/minimized window fails here and the
        // pill hides instead of teleporting.
        if (!Number.isFinite(x) || !Number.isFinite(y) ||
            w > 200 || h > 200 || w < 0 || h < 0) {
            this._caret = null;
            if (this._capsOn)
                this._hide();
            return;
        }
        const m = this._monitorFor(x + w / 2, y);
        const M = 64;
        if (x + w / 2 < m.x - M || x + w / 2 > m.x + m.width + M ||
            y < m.y - M || y > m.y + m.height + M) {
            this._caret = null;
            if (this._capsOn)
                this._hide();
            return;
        }
        this._caret = {x, y, w, h};
        if (this._layoutShowing)
            this._placeLayout();
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

    _currentLayoutShort() {
        try {
            const st = this._layoutSettings;
            const mru = st.get_value('mru-sources').deep_unpack();
            if (mru.length)
                return this._shortSourceId(mru[0][1]);
            const sources = st.get_value('sources').deep_unpack();
            const cur = st.get_uint('current');
            if (sources[cur])
                return this._shortSourceId(sources[cur][1]);
        } catch {
            // schema without sources (locked-down session)
        }
        return '';
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
        // Same rules as the caps pill (caret required). Preempts a
        // showing caps pill; the timer hands back to it.
        if (!this._caret)
            return;
        this._layoutLabel.set_text(id);
        this._layoutShowing = true;
        this._updateWant();
        this._placeLayout();
        this._layoutPill.visible = true;
        this._layoutPill.remove_all_transitions();
        this._layoutPill.ease({
            opacity: 255,
            duration: FADE_IN_MS,
            mode: Clutter.AnimationMode.EASE_OUT_CUBIC,
        });
        if (this._layoutTimerId)
            GLib.source_remove(this._layoutTimerId);
        this._layoutTimerId = GLib.timeout_add(
            GLib.PRIORITY_DEFAULT, LAYOUT_HOLD_MS, () => {
                this._layoutTimerId = 0;
                this._layoutShowing = false;
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
        // Width estimate (actor width settles a frame after set_text) —
        // keeps the flash centered for its whole second, no re-place.
        const id = this._layoutLabel.get_text() || '';
        const w = Math.max(PILL_W, id.length * 10 + 26);
        const c = this._caret;
        const mon = this._monitorFor(c.x + c.w / 2, c.y);
        let x = Math.round(c.x + c.w / 2 - w / 2);
        let y = Math.round(c.y + c.h + GAP);
        if (y + PILL_H > mon.y + mon.height)
            y = Math.round(c.y - GAP - PILL_H);
        x = Math.max(mon.x, Math.min(mon.x + mon.width - w, x));
        y = Math.max(mon.y, Math.min(mon.y + mon.height - PILL_H, y));
        this._layoutPill.set_position(x, y);
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
