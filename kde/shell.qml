//@ pragma UseQApplication
// macospills KDE overlay — full-screen click-through layer with a pill
// that eases to the caret (smooth follow) or the on-screen fallback.
//
// Driven by capspill.py via /tmp/macospills-kde.json (FileView watch):
//   {"caps": bool, "hasCaret": bool, "cx","cy","cw","ch": int}
// Placement mirrors DESIGN.md: below the caret (6px gap), above when no
// room, clamped to the monitor; bottom-center fallback without a caret.

import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import QtQuick

ShellRoot {
    id: root

    property int edgeGap: 86
    property int gap: 6
    property int px: 0
    property int py: 0
    property bool capsOn: kv.caps
    property bool hideIt: kv.hide
    property bool hasCaret: kv.hasCaret
    property int cx: kv.cx
    property int cy: kv.cy
    property int cw: kv.cw
    property int ch: kv.ch
    property bool atCaret: root.capsOn && root.hasCaret

    onCapsOnChanged: root.applyState()
    onHideItChanged: root.applyState()
    onHasCaretChanged: root.applyState()
    onCxChanged: if (root.atCaret) root.updatePosition()
    onCyChanged: if (root.atCaret) root.updatePosition()
    onCwChanged: if (root.atCaret) root.updatePosition()
    onChChanged: if (root.atCaret) root.updatePosition()

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
    // capsule-to-caret.
    function updatePosition() {
        if (!root.capsOn || root.hideIt) {
            pill.hide();
            return;
        }
        let mon, x, y;
        if (root.atCaret) {
            mon = root.monitorFor(root.cx + root.cw / 2, root.cy);
            x = Math.round(root.cx + root.cw / 2 - pill.implicitWidth / 2);
            y = Math.round(root.cy + root.ch + root.gap - pill.margin);
            if (y + pill.implicitHeight > mon.y + mon.height)
                y = Math.round(root.cy - root.gap - pill.capsuleHeight - pill.margin);
        } else {
            mon = Quickshell.screens.length ? Quickshell.screens[0] : ({x: 0, y: 0, width: 1920, height: 1080});
            x = Math.round(mon.x + (mon.width - pill.implicitWidth) / 2);
            y = Math.round(mon.y + mon.height * 0.92 - pill.implicitHeight);
        }
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
        if (!root.capsOn || root.hideIt) {
            pill.hide();
            return;
        }
        root.updatePosition();
        pill.show();
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
    }
}
