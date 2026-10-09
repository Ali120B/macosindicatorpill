//@ pragma UseQApplication
// macospills — macOS-style Caps Lock pill for Hyprland (Quickshell).
//
// Shows a small ⇪ capsule while Caps Lock is ON, placed at the text
// caret like macOS.
//
// Caret source: the caret-bridge plugin (hyprland/caret-bridge/) reads
// the Wayland text-input cursor rectangle in-compositor and publishes
// /tmp/macospills-hypr-caret.json. Event-driven, covers terminals
// (kitty/foot/alacritty, needs fcitx5 running), GTK, Qt, Firefox,
// Electron+--enable-wayland-ime. No caret -> hidden (same call as KDE;
// the old AT-SPI fallback is retired — it held stale per-app rects).
//
// Caps state is read from the kernel LED
// (/sys/class/leds/*capslock/brightness), so it needs no XWayland.
//
// Run:
//   ./run.sh  (starts overlay; auto-loads plugin, starts fcitx5 if needed)
// Test without toggling caps:
//   quickshell ipc -p ~/projects/macospills/hyprland call capspill reveal
//   quickshell ipc -p ~/projects/macospills/hyprland call capspill hide
// Autostart (Hyprland):
//   exec-once = ~/projects/macospills/hyprland/run.sh
//   exec-once = hyprctl plugin load ~/projects/macospills/hyprland/caret-bridge/build/macospills-caret-bridge.so

import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import QtQuick

ShellRoot {
    id: root

    // --- config -------------------------------------------------------
    property int gap: 6      // px between caret and pill (DESIGN.md)
    property int pollMs: 150 // caps LED poll interval
    property bool capsOnFocus: true // re-pop pill on window change while on

    // --- state --------------------------------------------------------
    property bool capsOn: false
    property int px: 0
    property int py: 0
    property int showCalls: 0
    property int hideCalls: 0
    property int pokeCalls: 0
    property int stuckTicks: 0 // consecutive ticks with showing&&opacity~0
    // caret directly from the bridge (sole source; AT-SPI retired)
    property bool hasCaret: bridge.hasCaret
    property int cx: bridge.x
    property int cy: bridge.y
    property int cw: bridge.w
    property int ch: bridge.h
    property int caretWin: bridge.win
    property int caretAge: bridge.age
    property string layout: bridge.layout
    property string lastLayout: ""
    property bool seenLayout: false
    property int lpx: 0
    property int lpy: 0
    property bool atCaret: root.capsOn && root.armed && root.hasCaret
    // First-key arming: the pill appears only after live typing in the
    // focused field — never on the caps toggle or a focus jump alone.
    // Latches till caps off / focus change / caret loss (each needs a
    // fresh keypress). Order-safe: baseline resets also disarm, so a
    // focus arrival can never arm, and typing always can.
    property bool armed: false
    property bool armLive: false
    property int armCx: 0
    property int armCy: 0
    property int armCw: 0
    property int armCh: 0

    onCapsOnChanged: root.applyState()
    onAtCaretChanged: root.applyState()
    onHasCaretChanged: {
        if (!root.hasCaret) {
            root.resetArm();
            layoutTimer.stop();
            layoutPill.hide();
        }
    }
    onCaretWinChanged: {
        root.resetArm();
        layoutTimer.stop();
        layoutPill.hide();
        if (root.capsOn && root.capsOnFocus)
            pill.poke();
    }
    onLayoutChanged: root.onLayoutSwitch()
    onCxChanged: {
        if (root.capsOn)
            root.noteCaret();
        if (root.atCaret)
            root.updatePosition();
        if (layoutPill.showing)
            root.updateLayoutPosition();
    }
    onCyChanged: {
        if (root.capsOn)
            root.noteCaret();
        if (root.atCaret)
            root.updatePosition();
        if (layoutPill.showing)
            root.updateLayoutPosition();
    }
    onCwChanged: {
        if (root.capsOn)
            root.noteCaret();
        if (root.atCaret)
            root.updatePosition();
        if (layoutPill.showing)
            root.updateLayoutPosition();
    }
    onChChanged: {
        if (root.capsOn)
            root.noteCaret();
        if (root.atCaret)
            root.updatePosition();
        if (layoutPill.showing)
            root.updateLayoutPosition();
    }

    function setCaps(on: bool) {
        if (on === root.capsOn)
            return;
        root.capsOn = on;
        if (!on) {
            root.resetArm();
            pill.hide();
        } else {
            // Preempt any layout flash. Strict first-key rule: the
            // toggle arms nothing — not even a live caret. First
            // keypress arms.
            layoutTimer.stop();
            layoutPill.hide();
            root.resetArm();
        }
    }

    function resetArm() {
        root.armed = false;
        root.armLive = false;
    }

    // Records live typing: rect->rect movement with a caret up arms.
    // Arrivals (baseline null) only snapshot. Called on every caret
    // step while caps is on.
    function noteCaret() {
        if (!root.hasCaret)
            return;
        if (root.armLive
            && (root.cx !== root.armCx || root.cy !== root.armCy
                || root.cw !== root.armCw || root.ch !== root.armCh))
            root.armed = true;
        root.armCx = root.cx;
        root.armCy = root.cy;
        root.armCw = root.cw;
        root.armCh = root.ch;
        root.armLive = true;
    }

    function monitorFor(x, y) {
        const screens = Quickshell.screens;
        for (let i = 0; i < screens.length; ++i) {
            const m = screens[i];
            if (x >= m.x && x < m.x + m.width && y >= m.y && y < m.y + m.height)
                return m;
        }
        return screens.length ? screens[0] : ({x: 0, y: 0, width: 1920, height: 1080});
    }

    // Move only — never touches the fade. Called on every tick and
    // every caret step; small typing steps glide, large jumps (tab /
    // field switch) snap so the pill never slides from a stale pos.
    // Positioned by capsule edge: pill x/y is the Item top-left but the
    // visible capsule starts `margin` inside it, so the DESIGN.md 6px gap
    // is capsule-to-caret, not margin-to-caret.
    // No caret (or caps off) -> hide: a pill with nowhere to point is
    // worse than none (same call as the KDE backend). There is no
    // bottom-center fallback anymore.
    function updatePosition() {
        if (!root.capsOn || !root.hasCaret) {
            pill.hide();
            return;
        }
        const mon = root.monitorFor(root.cx + root.cw / 2, root.cy);
        let x = Math.round(root.cx + root.cw / 2 - pill.implicitWidth / 2);
        let y = Math.round(root.cy + root.ch + root.gap - pill.margin);
        if (y + pill.implicitHeight > mon.y + mon.height)
            y = Math.round(root.cy - root.gap - pill.capsuleHeight - pill.margin);
        x = Math.max(mon.x, Math.min(mon.x + mon.width - pill.implicitWidth, x));
        y = Math.max(mon.y, Math.min(mon.y + mon.height - pill.implicitHeight, y));
        const far = Math.hypot(x - pill.x, y - pill.y) > 80;
        if (far) {
            bx.enabled = false;
            by.enabled = false;
        }
        root.px = x;
        root.py = y;
        if (far) {
            // Re-enable next loop: same-frame re-enable still glides
            // because the binding propagates after this JS returns.
            Qt.callLater(function() {
                bx.enabled = true;
                by.enabled = true;
            });
        }
    }

    // Move + ensure visible. Called on real state transitions
    // (caps on/off, caret lost/found) and by the tick reconciler when
    // the pill should be up but isn't (e.g. a show() that fired before
    // the item's animations were ready at startup). show() restarts the
    // fade — fine here because transitions are rare, unlike the tick.
    function applyState() {
        if (!root.atCaret) {
            pill.hide();
            return;
        }
        root.updatePosition();
        pill.show();
    }

    // Layout flash (macOS input-source pill): 1 s at the caret on real
    // layout switches. Same visibility rules (caret required), and the
    // held caps pill wins conflicts. First value is the seed, not a
    // switch — never flashes at startup.
    function onLayoutSwitch() {
        if (!root.seenLayout) {
            root.seenLayout = true;
            root.lastLayout = root.layout;
            return;
        }
        if (root.layout === root.lastLayout || !root.layout)
            return;
        root.lastLayout = root.layout;
        root.showLayoutFlash(root.layout);
    }

    // Flash appears exactly at the caret and stays there — snapped,
    // never glided in from the last spot, never following. Preempts a
    // showing caps pill (rule 1); the 1 s timer hands back to it.
    function showLayoutFlash(name) {
        if (!name || !root.hasCaret)
            return;
        layoutPill.text = name;
        pill.hide();
        lx.enabled = false;
        ly.enabled = false;
        root.updateLayoutPosition();
        layoutPill.show();
        layoutTimer.restart();
        // Width settles a frame after the text change — recenter once,
        // then re-enable follow glide.
        Qt.callLater(function() {
            if (layoutPill.showing)
                root.updateLayoutPosition();
            lx.enabled = true;
            ly.enabled = true;
        });
    }

    // Same placement as updatePosition but for the layout pill's own
    // size. No fade touched; follows the caret while flashing.
    function updateLayoutPosition() {
        const mon = root.monitorFor(root.cx + root.cw / 2, root.cy);
        let x = Math.round(root.cx + root.cw / 2 - layoutPill.implicitWidth / 2);
        let y = Math.round(root.cy + root.ch + root.gap - layoutPill.margin);
        if (y + layoutPill.implicitHeight > mon.y + mon.height)
            y = Math.round(root.cy - root.gap - layoutPill.capsuleHeight - layoutPill.margin);
        x = Math.max(mon.x, Math.min(mon.x + mon.width - layoutPill.implicitWidth, x));
        y = Math.max(mon.y, Math.min(mon.y + mon.height - layoutPill.implicitHeight, y));
        root.lpx = x;
        root.lpy = y;
    }

    Timer {
        id: pollTimer
        interval: root.pollMs
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: pollProc.running = true
    }

    // Layout flash hold: 1 s like macOS, then fade out. Re-switching
    // restarts it (no blink-through-hide). On expiry hands back to the
    // caps pill if it still applies.
    Timer {
        id: layoutTimer
        interval: 1000
        running: false
        repeat: false
        onTriggered: {
            layoutPill.hide();
            if (root.atCaret)
                pill.show();
        }
    }

    Process {
        id: pollProc
        // Caps LED only (cheap `cat`). Focus changes come event-driven
        // from the bridge `win` sequence — no more `hyprctl` fork here.
        command: ["bash", "-c", "n=$(cat /sys/class/leds/*capslock/brightness 2>/dev/null | grep -c 1); if [ \"$n\" -gt 0 ]; then echo caps=1; else echo caps=0; fi"]
        stdout: StdioCollector {
            onStreamFinished: {
                const m = /caps=(\d)/.exec(this.text.trim() || "");
                const on = !!(m && m[1] === "1");
                root.setCaps(on);
                // Reconciler: move every tick (smooth follow, no fade
                // restart), and re-show if the pill should be up but
                // isn't — heals a show() lost to startup racing or any
                // missed event. No blink: show() only fires while hidden.
                // Plus a stuck-fade healer: if showing stayed true while
                // opacity sat ~0 for a few ticks (fade swallowed before
                // the render loop was ready), kick it once.
                if (root.capsOn) {
                    if (!pill.showing) {
                        root.stuckTicks = 0;
                        root.applyState();
                    } else if (pill.opacity < 0.05) {
                        root.stuckTicks++;
                        if (root.stuckTicks >= 3) {
                            root.stuckTicks = 0;
                            pill.show();
                        }
                        root.updatePosition();
                    } else {
                        root.stuckTicks = 0;
                        root.updatePosition();
                    }
                } else {
                    root.stuckTicks = 0;
                }
            }
        }
    }

    // bridge caret file (sole source)
    // file shape: {"hasCaret":bool,"x","y","w","h","win"} maps 1:1
    // ("why"/"app" keys are diagnostics, ignored here; "win" is the
    // focus-generation counter driving the poke() above)
    FileView {
        path: "/tmp/macospills-hypr-caret.json"
        watchChanges: true
        onFileChanged: reload()
        JsonAdapter {
            id: bridge
            property bool hasCaret: false
            property int x: 0
            property int y: 0
            property int w: 0
            property int h: 0
            property int win: 0
            property int age: -1
            property string layout: ""
        }
    }

    IpcHandler {
        target: "capspill"
        // NOTE: named `reveal`, not `show` — `show` is itself an `ipc`
        // subcommand and the CLI steals `call capspill show` (prints
        // target info instead of calling). `hide` has no such clash.
        function reveal() { root.showCalls++; pill.show(); }
        function hide() { root.hideCalls++; pill.hide(); }
        function poke() { root.pokeCalls++; pill.poke(); }
        // Direct flash for switchers fcitx owns (the compositor layout
        // event doesn't fire for fcitx-driven switches): same guards as
        // the bus path — caret required, held caps wins.
        function flashLayout(name: string) {
            if (!name)
                return;
            root.seenLayout = true;
            root.lastLayout = name;
            root.showLayoutFlash(name);
        }
        function debug(): string {
            return JSON.stringify({
                capsOn: root.capsOn,
                hasCaret: root.hasCaret,
                atCaret: root.atCaret,
                cx: root.cx, cy: root.cy, cw: root.cw, ch: root.ch,
                win: root.caretWin,
                age: root.caretAge,
                armed: root.armed,
                layout: root.layout, lastLayout: root.lastLayout,
                layoutShowing: layoutPill.showing,
                px: root.px, py: root.py,
                showing: pill.showing,
                opacity: pill.opacity,
                visible: pill.visible,
                showCalls: root.showCalls,
                hideCalls: root.hideCalls,
                pokeCalls: root.pokeCalls
            });
        }
    }

    PanelWindow {
        id: win
        color: "transparent"
        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }
        exclusionMode: ExclusionMode.Ignore
        mask: Region {}
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "macospills:caps"
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

        CapsPill {
            id: pill
            x: root.px
            y: root.py
            Behavior on x {
                id: bx
                NumberAnimation {
                    duration: 60
                    easing.type: Easing.OutCubic
                }
            }
            Behavior on y {
                id: by
                NumberAnimation {
                    duration: 60
                    easing.type: Easing.OutCubic
                }
            }
        }

        LayoutPill {
            id: layoutPill
            x: root.lpx
            y: root.lpy
            Behavior on x {
                id: lx
                NumberAnimation {
                    duration: 60
                    easing.type: Easing.OutCubic
                }
            }
            Behavior on y {
                id: ly
                NumberAnimation {
                    duration: 60
                    easing.type: Easing.OutCubic
                }
            }
        }
    }
}
