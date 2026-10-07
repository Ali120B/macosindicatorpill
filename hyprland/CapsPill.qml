import QtQuick
import QtQuick.Shapes

// macOS-style Caps Lock pill: a small light capsule with a dark ⇪ glyph
// (outlined arrow over a bar) and a soft shadow below it.
// Caps-only port of the idea in Solium's KeyboardPill — drawn from scratch:
// capsule 30px tall, 46px min width, fade in 90ms / out 140ms.
Item {
    id: pill

    property bool showing: false

    readonly property int capsuleHeight: 30
    readonly property int capsuleMinWidth: 46
    readonly property int margin: 14
    readonly property real stroke: 1.6
    readonly property color capsuleColor: "#0a84ff"
    readonly property color inkColor: "#ffffff"

    implicitWidth: capsule.width + 2 * pill.margin
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
    // Re-pop while already visible (e.g. focus changed with caps still on).
    function poke() {
        if (pill.showing)
            inAnim.restart();
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
        width: pill.capsuleMinWidth
        height: pill.capsuleHeight
        radius: height / 2
        color: pill.capsuleColor

        // ⇪ as macOS draws it: outlined arrow + bar below.
        Shape {
            anchors.centerIn: parent
            width: 16
            height: 16
            preferredRendererType: Shape.CurveRenderer

            ShapePath {
                strokeColor: pill.inkColor
                strokeWidth: pill.stroke
                fillColor: "transparent"
                joinStyle: ShapePath.RoundJoin
                capStyle: ShapePath.RoundCap
                startX: 8
                startY: 1.5
                PathLine { x: 14.5; y: 7 }
                PathLine { x: 11; y: 7 }
                PathLine { x: 11; y: 9.5 }
                PathLine { x: 5; y: 9.5 }
                PathLine { x: 5; y: 7 }
                PathLine { x: 1.5; y: 7 }
                PathLine { x: 8; y: 1.5 }
            }
            ShapePath {
                strokeColor: pill.inkColor
                strokeWidth: pill.stroke
                fillColor: "transparent"
                joinStyle: ShapePath.RoundJoin
                PathRectangle { x: 5; y: 12; width: 6; height: 2.5; radius: 1 }
            }
        }
    }
}
