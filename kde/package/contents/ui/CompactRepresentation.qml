import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.kirigami as Kirigami

import "../code/forgejo.js" as F

// The panel item (MenuBarRenderer in Logo.swift): the logo with a badge, number, dot or nothing.
MouseArea {
    id: compact

    readonly property bool vertical: Plasmoid.formFactor === PlasmaCore.Types.Vertical
    readonly property bool mono: Plasmoid.configuration.iconColor === "monochrome"
    readonly property string badgeStyle: Plasmoid.configuration.badgeStyle
    readonly property int count: root.badgeCount
    readonly property bool showNumber: badgeStyle === "number" && count > 0 && !vertical
    readonly property real side: Math.min(vertical ? width : height, Kirigami.Units.iconSizes.large)
    readonly property real logoSide: Kirigami.Units.iconSizes.roundedIconSize(side * 0.8)

    Layout.minimumWidth: vertical ? -1 : row.implicitWidth
    Layout.preferredWidth: Layout.minimumWidth
    Layout.minimumHeight: vertical ? side : -1
    Layout.preferredHeight: Layout.minimumHeight

    acceptedButtons: Qt.LeftButton | Qt.MiddleButton
    hoverEnabled: true
    onClicked: mouse => {
        if (mouse.button === Qt.MiddleButton) root.refresh(true)
        else root.expanded = !root.expanded
    }

    RowLayout {
        id: row
        anchors.centerIn: parent
        spacing: Math.round(Kirigami.Units.smallSpacing / 2)

        Item {
            Layout.preferredWidth: compact.vertical ? compact.width : Math.max(compact.side, compact.logoSide)
            Layout.preferredHeight: compact.vertical ? compact.side : compact.height

            Logo {
                id: logo
                anchors.centerIn: parent
                width: compact.logoSide
                height: compact.logoSide
                orange: compact.mono ? Kirigami.Theme.textColor : root.forgejoOrange
                red: compact.mono ? Kirigami.Theme.textColor : root.forgejoRed
                // Dim while loading, and (optionally) when there's nothing to read.
                opacity: root.iconState === "loading" ? 0.45
                    : (compact.count === 0 && Plasmoid.configuration.dimWhenEmpty && root.iconState === "ok") ? 0.55
                    : 1
            }

            // Count badge, tucked over the logo's top-right corner.
            Rectangle {
                visible: compact.badgeStyle === "badge" && compact.count > 0
                    || (compact.badgeStyle === "number" && compact.count > 0 && compact.vertical)
                readonly property real h: Math.max(10, Math.round(compact.logoSide * 0.55))
                height: h
                width: Math.max(h, badgeText.implicitWidth + h * 0.5)
                radius: h / 2
                color: compact.mono ? Kirigami.Theme.textColor : Kirigami.Theme.negativeTextColor
                border.width: 1
                border.color: Kirigami.Theme.backgroundColor
                anchors.right: logo.right
                anchors.top: logo.top
                anchors.rightMargin: -Math.round(h * 0.35)
                anchors.topMargin: -Math.round(h * 0.25)
                Text {
                    id: badgeText
                    anchors.centerIn: parent
                    text: F.countText(compact.count)
                    color: compact.mono ? Kirigami.Theme.backgroundColor : "white"
                    font.pixelSize: Math.round(parent.h * 0.72)
                    font.weight: Font.Bold
                    font.features: { "tnum": 1 }
                }
            }

            // Unread dot, or an orange dot when something's wrong.
            Rectangle {
                readonly property bool errorDot: root.iconState === "error"
                visible: errorDot || (compact.badgeStyle === "dot" && compact.count > 0)
                readonly property real d: Math.max(5, Math.round(compact.logoSide * 0.32))
                width: d
                height: d
                radius: d / 2
                color: errorDot ? Kirigami.Theme.neutralTextColor
                    : compact.mono ? Kirigami.Theme.textColor : Kirigami.Theme.negativeTextColor
                border.width: 1
                border.color: Kirigami.Theme.backgroundColor
                x: logo.x + logo.width - d + Math.round(d * 0.3)
                y: errorDot ? logo.y + logo.height - d : logo.y
            }
        }

        Text {
            visible: compact.showNumber
            text: F.countText(compact.count)
            color: Kirigami.Theme.textColor
            font.weight: Font.DemiBold
            font.features: { "tnum": 1 }
            Layout.rightMargin: Kirigami.Units.smallSpacing
        }
    }
}
