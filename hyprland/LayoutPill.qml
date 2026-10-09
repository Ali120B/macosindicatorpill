import QtQuick

// macOS-style input-source flash: same blue capsule as CapsPill, but a
// tracked-out source code ("EN", "AR") instead of the ⇪ glyph.
// Natural width hugging the text: the capsule binds the label's
// implicitWidth (content size, always current) with slim ~8px side
// padding and a 46px floor — never hand-measured (paintedWidth goes
// stale on a hidden actor and clips to "..."). Ellipsis off.
Item {
    id: pill

    property bool showing: false
    property string text: ""

    readonly property int capsuleHeight: 30
    readonly property int capsuleMinWidth: 46
    readonly property int margin: 14
    readonly property int hPad: 8
    readonly property color capsuleColor: "#0a84ff"
    readonly property color inkColor: "#ffffff"

    implicitWidth: Math.max(capsuleMinWidth, label.implicitWidth + 2 * pill.hPad) + 2 * pill.margin
    implicitHeight: pill.capsuleHeight + 2 * pill.margin

    opacity: 0
    visible: opacity > 0.01

    function show() {
        pill.showing = true;
        inAnim.restart();
    }
    function hide() {
        pill.showing = false;
        outAnim.restart();
    }

    NumberAnimation {
        id: inAnim
        target: pill
        property: "opacity"
        from: 0
        to: 1
        duration: 90
        easing.type: Easing.OutCubic
    }
    NumberAnimation {
        id: outAnim
        target: pill
        property: "opacity"
        to: 0
        duration: 140
        easing.type: Easing.OutCubic
    }

    // Soft shadow below the capsule, stacked rings with quadratic falloff
    // (no shader, identical in software rendering).
    Repeater {
        model: pill.margin - 2
        Rectangle {
            required property int index
            readonly property real out: (ring.index + 1) / (pill.margin - 2)
            id: ring
            x: (pill.width - width) / 2
            y: (pill.height - height) / 2 + 4
            width: capsule.width + 2 * (ring.index + 1)
            height: capsule.height + 2 * (ring.index + 1)
            radius: height / 2
            color: Qt.rgba(0, 0, 0, 0.028 * (1 - ring.out) * (1 - ring.out) + 0.003)
        }
    }

    Rectangle {
        id: capsule
        anchors.centerIn: parent
        width: Math.max(pill.capsuleMinWidth, label.implicitWidth + 2 * pill.hPad)
        height: pill.capsuleHeight
        radius: height / 2
        color: pill.capsuleColor

        Text {
            id: label
            anchors.centerIn: parent
            text: pill.text
            color: pill.inkColor
            font.family: "Inter"
            font.pixelSize: 13
            font.weight: Font.DemiBold
            font.letterSpacing: 2
            wrapMode: Text.NoWrap
            elide: Text.ElideNone
        }
    }
}
