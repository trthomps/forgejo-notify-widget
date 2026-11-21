import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami

import "../code/forgejo.js" as F

// One notification (PopoverView.swift NotificationRow). Click opens it; ✓ marks it read;
// right-click for more.
ColumnLayout {
    id: row

    property var item: null              // { thread, reason }
    property bool dimmed: false
    property string sectionTitle: ""
    readonly property var thread: item ? item.thread : null
    readonly property string tint: thread ? F.tintFor(thread) : "neutral"

    spacing: 0

    PlasmaComponents.Label {
        visible: row.sectionTitle !== ""
        Layout.fillWidth: true
        leftPadding: Kirigami.Units.largeSpacing
        topPadding: Kirigami.Units.largeSpacing
        bottomPadding: Kirigami.Units.smallSpacing
        text: row.sectionTitle.toUpperCase()
        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
        font.weight: Font.DemiBold
        opacity: 0.7
    }

    MouseArea {
        id: area
        Layout.fillWidth: true
        implicitHeight: content.implicitHeight + Kirigami.Units.smallSpacing * 3
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: Qt.PointingHandCursor
        onClicked: mouse => {
            if (mouse.button === Qt.RightButton) menu.popup()
            else root.open(row.thread)
        }

        Rectangle {
            anchors.fill: parent
            color: Kirigami.Theme.highlightColor
            opacity: area.containsMouse ? 0.15 : 0
        }

        RowLayout {
            id: content
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Kirigami.Units.largeSpacing
            anchors.rightMargin: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.largeSpacing
            opacity: row.dimmed ? 0.6 : 1

            Kirigami.Icon {
                Layout.alignment: Qt.AlignTop
                Layout.topMargin: 2
                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                Layout.preferredHeight: Kirigami.Units.iconSizes.small
                source: row.thread ? F.iconFor(row.thread) : ""
                isMask: true
                color: row.tint === "positive" ? Kirigami.Theme.positiveTextColor
                    : row.tint === "negative" ? Kirigami.Theme.negativeTextColor
                    : row.tint === "merged" ? "#8957e5"
                    : Kirigami.Theme.disabledTextColor
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing
                    PlasmaComponents.Label {
                        text: row.thread ? row.thread.repo : ""
                        elide: Text.ElideMiddle
                        font: Kirigami.Theme.smallFont
                        opacity: 0.7
                        Layout.fillWidth: true
                        Layout.maximumWidth: implicitWidth
                    }
                    PlasmaComponents.Label {
                        visible: text !== ""
                        text: row.thread ? F.number(row.thread) : ""
                        font: Kirigami.Theme.smallFont
                        opacity: 0.45
                    }
                    Kirigami.Icon {
                        visible: !!row.thread && row.thread.pinned
                        source: "pin"
                        Layout.preferredWidth: Math.round(Kirigami.Units.iconSizes.small * 0.75)
                        Layout.preferredHeight: Layout.preferredWidth
                        opacity: 0.7
                    }
                    Item { Layout.fillWidth: true }
                    Rectangle {
                        visible: !!row.item && row.item.reason !== null
                        radius: height / 2
                        color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.08)
                        implicitWidth: Math.min(reasonLabel.implicitWidth + Kirigami.Units.smallSpacing * 2, Kirigami.Units.gridUnit * 8)
                        implicitHeight: reasonLabel.implicitHeight + 2
                        PlasmaComponents.Label {
                            id: reasonLabel
                            anchors.centerIn: parent
                            width: Math.min(implicitWidth, parent.width - Kirigami.Units.smallSpacing * 2)
                            elide: Text.ElideRight
                            text: row.item && row.item.reason ? row.item.reason : ""
                            font: Kirigami.Theme.smallFont
                            opacity: 0.7
                        }
                    }
                    PlasmaComponents.Label {
                        text: row.thread ? F.ago(row.thread.updatedAt, root.now, true) : ""
                        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                        font.features: { "tnum": 1 }
                        opacity: 0.7
                    }
                }

                PlasmaComponents.Label {
                    Layout.fillWidth: true
                    text: row.thread ? row.thread.title : ""
                    wrapMode: Text.Wrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                    font.weight: row.thread && row.thread.unread ? Font.Medium : Font.Normal
                    opacity: row.thread && row.thread.unread ? 1 : 0.7
                }
            }

            Item {
                Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium + Kirigami.Units.smallSpacing
                Layout.preferredHeight: Layout.preferredWidth
                Layout.alignment: Qt.AlignVCenter

                PlasmaComponents.ToolButton {
                    anchors.fill: parent
                    visible: area.containsMouse && !!row.thread && row.thread.unread
                    icon.name: "checkmark"
                    onClicked: root.markRead([row.thread])
                    PlasmaComponents.ToolTip { text: i18n("Mark as read") }
                }
                Rectangle {
                    visible: !area.containsMouse && !!row.thread && row.thread.unread
                    anchors.centerIn: parent
                    width: 7
                    height: 7
                    radius: 3.5
                    color: Kirigami.Theme.highlightColor
                }
            }
        }

        PlasmaComponents.ToolTip {
            text: row.thread ? (F.webURL(row.thread) || "") : ""
            visible: area.containsMouse && text !== ""
            delay: Kirigami.Units.toolTipDelay * 2
        }
    }

    PlasmaComponents.Menu {
        id: menu
        PlasmaComponents.MenuItem {
            text: i18n("Open")
            icon.name: "internet-web-browser"
            onTriggered: root.open(row.thread)
        }
        PlasmaComponents.MenuItem {
            text: i18n("Mark as Read")
            icon.name: "mail-mark-read"
            enabled: !!row.thread && row.thread.unread
            onTriggered: root.markRead([row.thread])
        }
        PlasmaComponents.MenuItem {
            text: i18n("Copy Link")
            icon.name: "edit-copy"
            enabled: !!row.thread && F.webURL(row.thread) !== null
            onTriggered: { clip.text = F.webURL(row.thread); clip.selectAll(); clip.copy() }
        }
        PlasmaComponents.MenuSeparator {}
        PlasmaComponents.MenuItem {
            text: row.thread ? i18n("Hide Notifications from %1", row.thread.repo) : ""
            icon.name: "view-hidden"
            onTriggered: root.hideRepo(row.thread.repo)
        }
    }

    // Clipboard access without extra modules.
    TextEdit { id: clip; visible: false }
}
