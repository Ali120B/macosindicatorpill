// macospills KWin watcher — pushes the active window's geometry to the
// capspill daemon over D-Bus. Loaded at daemon start via
// org.kde.KWin /Scripting loadScript (no package install, no relog).
//
// Daemon service: org.macospills.kde /pill org.macospills.Pill ActiveWindow
//   (frameX, frameY, frameW, frameH, clientX, clientY, appId, caption)
//   + ToggleLayout (Ctrl+Shift+Space flips fcitx5 keyboard-us/ara).
// clientX/clientY are -1 when the API does not expose client geometry
// (server-side decorations then need a per-app offset — verified per app).

function push(w) {
    if (!w) {
        // desktop / all minimized: explicit null so the daemon drops the
        // stale caret immediately instead of parking the pill at it
        callDBus('org.macospills.kde', '/pill', 'org.macospills.Pill', 'ActiveWindow',
            -1, -1, 0, 0, -1, -1, '', '');
        return;
    }
    var f = w.frameGeometry;
    var cx = -1, cy = -1;
    try {
        if (w.clientGeometry) {
            cx = Math.round(w.clientGeometry.x);
            cy = Math.round(w.clientGeometry.y);
        }
    } catch (e) {
        cx = -1; cy = -1;
    }
    callDBus('org.macospills.kde', '/pill', 'org.macospills.Pill', 'ActiveWindow',
        Math.round(f.x), Math.round(f.y),
        Math.round(f.width), Math.round(f.height),
        cx, cy,
        String(w.resourceClass || ''), String(w.caption || ''));
}

var tracked = null;
function onGeo() {
    push(workspace.activeWindow);
}
function track(w) {
    if (tracked) {
        try { tracked.frameGeometryChanged.disconnect(onGeo); } catch (e) {}
        tracked = null;
    }
    if (w) {
        tracked = w;
        try { w.frameGeometryChanged.connect(onGeo); } catch (e) {}
    }
}

workspace.windowActivated.connect(function (client) {
    var w = client || workspace.activeWindow;
    track(w);
    push(w);
});

// Own Ctrl+Shift+Space (like the GNOME backend): flip fcitx5 us/ara via
// the daemon. Unregistered automatically when the script unloads.
try {
    registerShortcut("Macospills Toggle Layout",
        "macospills: toggle keyboard layout (us/ara)",
        "Ctrl+Shift+Space",
        function () {
            callDBus('org.macospills.kde', '/pill', 'org.macospills.Pill',
                'ToggleLayout');
        });
} catch (e) {}

track(workspace.activeWindow);
push(workspace.activeWindow);
