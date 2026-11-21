import QtQuick
import QtQuick.Shapes

// The Forgejo mark, drawn from its SVG geometry (212×212 viewBox) so it stays crisp at any size (Logo.swift).
Item {
    id: logo

    property color orange: "#ff6600"
    property color red: "#d40000"

    implicitWidth: 16
    implicitHeight: 16

    component Arm: ShapePath {
        property real top
        fillColor: "transparent"
        strokeWidth: 30
        capStyle: ShapePath.FlatCap
        joinStyle: ShapePath.MiterJoin
        startX: 58; startY: 168
        // M58 168 V(top+50) a50 50 0 0 1 50-50 h20
        PathLine { x: 58; y: top + 50 }
        PathArc { x: 108; y: top; radiusX: 50; radiusY: 50 }
        PathLine { x: 128; y: top }
    }

    component Ring: ShapePath {
        property real cx
        property real cy
        fillColor: "transparent"
        strokeWidth: 15
        startX: cx - 18; startY: cy
        PathArc { x: cx + 18; y: cy; radiusX: 18; radiusY: 18 }
        PathArc { x: cx - 18; y: cy; radiusX: 18; radiusY: 18 }
    }

    Item {
        width: 212
        height: 212
        anchors.centerIn: parent
        scale: Math.min(logo.width, logo.height) / 212

        Shape {
            // The logo's own translate(6,6).
            x: 6
            y: 6
            preferredRendererType: Shape.CurveRenderer

            Arm { top: 20; strokeColor: logo.orange }
            Arm { top: 88; strokeColor: logo.red }
            Ring { cx: 142; cy: 20; strokeColor: logo.orange }
            Ring { cx: 142; cy: 88; strokeColor: logo.red }
            Ring { cx: 58; cy: 180; strokeColor: logo.red }
        }
    }
}
