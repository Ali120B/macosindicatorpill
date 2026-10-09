//@ pragma UseQApplication
// macospills KDE overlay — full-screen click-through layer with pills
// that track the caret exactly (direct-set per update, no glide:
// glide + dense caret commits rubber-band).
//
// Driven by capspill.py via /tmp/macospills-kde.json (FileView watch):
//   {"caps","hide","hasCaret","hasText","termFb","cx","cy","cw","ch",
//    "wx","wy","ww","wh","layout","fseq"}
// Placement mirrors DESIGN.md: below the caret (6px gap), above when no
// room, clamped to the monitor. Caps: caret exact; silent terminals
// (caret unknowable, always a textbox) fall back window-anchored and
// unarmed — otherwise no caret, no pill. Layout flash: caret preferred,
// bottom-center fallback while a textbox is focused, hidden on desktop
// / plain windows.

import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import QtQuick

ShellRoot {
    id: root

    property int gap: 6
    property int px: 0
    property int py: 0
    property int lpx: 0
    property int lpy: 0
    property string layout: kv.layout
    property string lastLayout: ""
    property bool seenLayout: false
    property bool capsOn: kv.caps
    property bool hideIt: kv.hide
    property bool hasCaret: kv.hasCaret
    property bool hasText: kv.hasText
    property bool termFb: kv.termFb
    property int fseq: kv.fseq
    property int wx: kv.wx
    property int wy: kv.wy
    property int ww: kv.ww
    property int wh: kv.wh
    // First-key arming (same rule as Hyprland): pill appears only after
    // live typing in the focused field. fseq resets it per focus.
    property bool armed: false
    property bool armLive: false
    property int armCx: 0
    property int armCy: 0
    property int armCw: 0
    property int armCh: 0
    property int cx: kv.cx
    property int cy: kv.cy
    property int cw: kv.cw
    property int ch: kv.ch
    property bool atCaret: root.capsOn && root.armed && root.hasCaret
    // Silent-terminal fallback: caps held in a terminal whose caret no
    // bus can report. Unarmed by necessity (no caret signal to arm
    // with) — shows while caps is on, window-anchored.
    property bool capsFb: root.capsOn && root.hasText && !root.hasCaret && root.termFb

    onCapsOnChanged: {
        root.resetArm();
        if (root.capsOn) {
            // Preempt any layout flash. Strict first-key rule: the
            // toggle arms nothing — not even a live caret. First
            // keypress arms. Turning OFF leaves a flash alone.
            layoutTimer.stop();
            layoutPill.hide();
        }
        root.applyState();
    }
    onHideItChanged: root.applyState()
    onAtCaretChanged: root.applyState()
    onCapsFbChanged: root.applyState()
    onHasCaretChanged: {
        if (!root.hasCaret) {
            root.resetArm();
            layoutTimer.stop();
            layoutPill.hide();
        }
    }
    onFseqChanged: {
        root.resetArm();
        layoutTimer.stop();
        layoutPill.hide();
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

    FileView {
        path: "/tmp/macospills-kde.json"
        watchChanges: true
        onFileChanged: reload()
        JsonAdapter {
            id: kv
            property bool caps: false
            property bool hide: false
            property bool hasCaret: false
            property bool hasText: false
            property bool termFb: false
            property int cx: 0
            property int cy: 0
            property int cw: 0
            property int ch: 0
            property int wx: 0
            property int wy: 0
            property int ww: 0
            property int wh: 0
            property string layout: ""
            property int fseq: 0
        }
    }

    Timer {
        id: layoutTimer
        interval: 1000
        running: false
        repeat: false
        onTriggered: {
            layoutPill.hide();
            root.applyState();
        }
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

    // Move only — never touches the fade. Direct-set per update, no
    // glide: every caret commit re-targets, and easing on dense updaters
    // rubber-bands forever (pill lags or sits). Positioned by capsule
    // edge (see hyprland/shell.qml): the 6px gap is capsule-to-caret.
    // Caret path needs atCaret (armed + caret up); silent terminals use
    // the window-anchored fallback path.
    function updatePosition() {
        if (root.atCaret) {
            const mon = root.monitorFor(root.cx + root.cw / 2, root.cy);
            let x = Math.round(root.cx + root.cw / 2 - pill.implicitWidth / 2);
            let y = Math.round(root.cy + root.ch + root.gap - pill.margin);
            if (y + pill.implicitHeight > mon.y + mon.height)
                y = Math.round(root.cy - root.gap - pill.capsuleHeight - pill.margin);
            x = Math.max(mon.x, Math.min(mon.x + mon.width - pill.implicitWidth, x));
            y = Math.max(mon.y, Math.min(mon.y + mon.height - pill.implicitHeight, y));
            root.px = x;
            root.py = y;
            return;
        }
        if (root.capsFb) {
            const xy = root.fallbackXY(pill.implicitWidth, pill.implicitHeight);
            root.px = xy[0];
            root.py = xy[1];
            return;
        }
        pill.hide();
    }

    function applyState() {
        if (!root.atCaret && !root.capsFb) {
            pill.hide();
            return;
        }
        root.updatePosition();
        pill.show();
    }

    function resetArm() {
        root.armed = false;
        root.armLive = false;
    }

    // Records live typing: a typing-like rect->rect step with a caret
    // up arms. Arrivals (baseline null) only snapshot. Big jumps are
    // clicks / field switches: re-baseline without arming, so a click
    // alone never shows the pill (strict first-key rule) while typing
    // (small advances, next char after a newline) always arms.
    function noteCaret() {
        if (!root.hasCaret)
            return;
        if (root.armLive
            && (root.cx !== root.armCx || root.cy !== root.armCy
                || root.cw !== root.armCw || root.ch !== root.armCh)) {
            const step = Math.abs(root.cx - root.armCx)
                + Math.abs(root.cy - root.armCy)
                + Math.abs(root.cw - root.armCw)
                + Math.abs(root.ch - root.armCh);
            if (step < 120)
                root.armed = true;
        }
        root.armCx = root.cx;
        root.armCy = root.cy;
        root.armCw = root.cw;
        root.armCh = root.ch;
        root.armLive = true;
    }

    // Layout flash (macOS input-source pill): 1 s on real switches.
    // Focus-gated, not caret-gated: a selected textbox is enough even
    // pre-first-keystroke (bottom-center fallback); desktop / plain
    // window stays hidden. Preempts a showing caps pill and hands back
    // to it on expiry. The first value is the seed, never a flash.
    // Re-switching restarts the 1 s hold.
    function onLayoutSwitch() {
        if (!root.seenLayout) {
            root.seenLayout = true;
            root.lastLayout = root.layout;
            return;
        }
        if (root.layout === root.lastLayout || !root.layout)
            return;
        root.lastLayout = root.layout;
        if (!root.hasCaret && !root.hasText)
            return;
        layoutPill.text = root.layout;
        pill.hide();
        root.updateLayoutPosition();
        layoutPill.show();
        layoutTimer.restart();
        // Width settles a frame after the text change — recenter once.
        Qt.callLater(function() {
            if (layoutPill.showing)
                root.updateLayoutPosition();
        });
    }

    // Same placement as updatePosition but for the layout pill's own
    // size; follows the caret while flashing (exact, no glide). No
    // caret but a focused textbox: bottom-center fallback at 92%
    // height, like GNOME. No fade touched.
    function updateLayoutPosition() {
        const w = layoutPill.implicitWidth;
        const h = layoutPill.implicitHeight;
        if (root.hasCaret) {
            const mon = root.monitorFor(root.cx + root.cw / 2, root.cy);
            let x = Math.round(root.cx + root.cw / 2 - w / 2);
            let y = Math.round(root.cy + root.ch + root.gap - layoutPill.margin);
            if (y + h > mon.y + mon.height)
                y = Math.round(root.cy - root.gap - layoutPill.capsuleHeight - layoutPill.margin);
            x = Math.max(mon.x, Math.min(mon.x + mon.width - w, x));
            y = Math.max(mon.y, Math.min(mon.y + mon.height - h, y));
            root.lpx = x;
            root.lpy = y;
            return;
        }
        const xy = root.fallbackXY(w, h);
        root.lpx = xy[0];
        root.lpy = xy[1];
    }

    // Bottom-center fallback at 92% height on the active window's
    // monitor (GNOME parity). Shared by the layout flash and the
    // silent-terminal caps fallback.
    function fallbackXY(w, h) {
        const mon = root.winMonitor();
        let x = Math.round(mon.x + mon.width / 2 - w / 2);
        let y = Math.round(mon.y + mon.height * 0.92 - h / 2);
        x = Math.max(mon.x, Math.min(mon.x + mon.width - w, x));
        y = Math.max(mon.y, Math.min(mon.y + mon.height - h, y));
        return [x, y];
    }

    // Monitor holding the active window (layout fallback anchor);
    // first screen when windowless (unreachable: callers gate on
    // hasText, which needs a window).
    function winMonitor() {
        if (root.ww > 0 && root.wh > 0)
            return root.monitorFor(root.wx + root.ww / 2, root.wy + root.wh / 2);
        const screens = Quickshell.screens;
        return screens.length ? screens[0] : ({x: 0, y: 0, width: 1920, height: 1080});
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
        WlrLayershell.namespace: "macospills:kde"
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

        CapsPill {
            id: pill
            x: root.px
            y: root.py
        }

        LayoutPill {
            id: layoutPill
            x: root.lpx
            y: root.lpy
            // Width settles after the text change; recenter exactly.
            onImplicitWidthChanged: {
                if (layoutPill.showing)
                    root.updateLayoutPosition();
            }
        }
    }
}
