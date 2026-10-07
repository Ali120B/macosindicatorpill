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
    property string lastAddr: ""
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
    property bool atCaret: root.capsOn && root.hasCaret

    onCapsOnChanged: root.applyState()
    onHasCaretChanged: root.applyState()
    onCxChanged: if (root.atCaret) root.updatePosition()
    onCyChanged: if (root.atCaret) root.updatePosition()
    onCwChanged: if (root.atCaret) root.updatePosition()
    onChChanged: if (root.atCaret) root.updatePosition()

    function setCaps(on: bool) {
        if (on === root.capsOn)
            return;
        root.capsOn = on;
        if (!on)
            pill.hide();
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
    // every caret step; the x/y Behaviors glide the pill smoothly.
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
        let y = Math.round(root.cy + root.ch + root.gap);
        if (y + pill.implicitHeight > mon.y + mon.height)
            y = Math.round(root.cy - root.gap - pill.implicitHeight);
        x = Math.max(mon.x, Math.min(mon.x + mon.width - pill.implicitWidth, x));
        y = Math.max(mon.y, Math.min(mon.y + mon.height - pill.implicitHeight, y));
        root.px = x;
        root.py = y;
    }

    // Move + ensure visible. Called on real state transitions
    // (caps on/off, caret lost/found) and by the tick reconciler when
    // the pill should be up but isn't (e.g. a show() that fired before
    // the item's animations were ready at startup). show() restarts the
    // fade — fine here because transitions are rare, unlike the tick.
    function applyState() {
        if (!root.capsOn || !root.hasCaret) {
            pill.hide();
            return;
        }
        root.updatePosition();
        pill.show();
    }

    Timer {
        id: pollTimer
        interval: root.pollMs
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: pollProc.running = true
    }

    Process {
        id: pollProc
        command: ["bash", "-c", "n=$(cat /sys/class/leds/*capslock/brightness 2>/dev/null | grep -c 1); if [ \"$n\" -gt 0 ]; then echo caps=1; else echo caps=0; fi; hyprctl activewindow -j 2>/dev/null | grep -o '\"address\": \"[^\"]*\"' | head -n1"]
        stdout: StdioCollector {
            onStreamFinished: {
                const lines = this.text.trim().split("\n");
                const m = /caps=(\d)/.exec(lines[0] || "");
                const on = !!(m && m[1] === "1");
                const addr = (lines.length > 1 ? lines[1] : "").trim();
                if (addr && addr !== root.lastAddr) {
                    root.lastAddr = addr;
                    if (on && root.capsOnFocus && root.capsOn)
                        pill.poke();
                }
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
    // file shape: {"hasCaret":bool,"x","y","w","h"} maps 1:1
    // ("why"/"app" keys are diagnostics, ignored here)
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
        function debug(): string {
            return JSON.stringify({
                capsOn: root.capsOn,
                hasCaret: root.hasCaret,
                atCaret: root.atCaret,
                cx: root.cx, cy: root.cy, cw: root.cw, ch: root.ch,
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
                NumberAnimation {
                    duration: 120
                    easing.type: Easing.OutCubic
                }
            }
            Behavior on y {
                NumberAnimation {
                    duration: 120
                    easing.type: Easing.OutCubic
                }
            }
        }
    }
}
