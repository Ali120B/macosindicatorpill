//@ pragma UseQApplication
// macospills KDE overlay — full-screen click-through layer with a pill
// that eases to the caret (smooth follow).
//
// Driven by capspill.py via /tmp/macospills-kde.json (FileView watch):
//   {"caps": bool, "hasCaret": bool, "cx","cy","cw","ch": int}
// Placement mirrors DESIGN.md: below the caret (6px gap), above when no
// room, clamped to the monitor. No caret: hidden (same call as Hyprland,
// the daemon sends hide:true — there is no on-screen fallback).

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
    property int fseq: kv.fseq
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

    onCapsOnChanged: {
        root.resetArm();
        layoutTimer.stop();
        layoutPill.hide();
        root.applyState();
    }
    onHideItChanged: root.applyState()
    onAtCaretChanged: root.applyState()
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
            property int cx: 0
            property int cy: 0
            property int cw: 0
            property int ch: 0
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
            if (root.atCaret)
                pill.show();
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

    // Move only — never touches the fade. Every caret step while typing
    // used to call applyState()->show(), restarting the 90ms fade from 0
    // each keystroke so the pill never reached full opacity. Positioned
    // by capsule edge (see hyprland/shell.qml): the 6px gap is
    // capsule-to-caret. Callers guarantee atCaret (armed + caret up).
    function updatePosition() {
        if (!root.atCaret) {
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
            Qt.callLater(function() {
                bx.enabled = true;
                by.enabled = true;
            });
        }
    }

    function applyState() {
        if (!root.atCaret) {
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

    // Layout flash (macOS input-source pill): 1 s at the caret on real
    // switches. Caret required; preempts a showing caps pill and hands
    // back to it on expiry. The first value is the seed, never a flash.
    function onLayoutSwitch() {
        if (!root.seenLayout) {
            root.seenLayout = true;
            root.lastLayout = root.layout;
            return;
        }
        if (root.layout === root.lastLayout || !root.layout)
            return;
        root.lastLayout = root.layout;
        if (!root.hasCaret)
            return;
        layoutPill.text = root.layout;
        pill.hide();
        llx.enabled = false;
        lly.enabled = false;
        root.updateLayoutPosition();
        layoutPill.show();
        layoutTimer.restart();
        Qt.callLater(function() {
            if (layoutPill.showing)
                root.updateLayoutPosition();
            llx.enabled = true;
            lly.enabled = true;
        });
    }

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
            Behavior on x {
                id: bx
                NumberAnimation {
                    duration: 150
                    easing.type: Easing.OutCubic
                }
            }
            Behavior on y {
                id: by
                NumberAnimation {
                    duration: 150
                    easing.type: Easing.OutCubic
                }
            }
        }

        LayoutPill {
            id: layoutPill
            x: root.lpx
            y: root.lpy
            Behavior on x {
                id: llx
                NumberAnimation {
                    duration: 80
                    easing.type: Easing.OutCubic
                }
            }
            Behavior on y {
                id: lly
                NumberAnimation {
                    duration: 80
                    easing.type: Easing.OutCubic
                }
            }
        }
    }
}
