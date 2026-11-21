import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.plasma.plasmoid
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.extras as PlasmaExtras
import org.kde.kirigami as Kirigami

import "../code/forgejo.js" as F

// The click-through list (PopoverView.swift).
PlasmaExtras.Representation {
    id: popup

    readonly property bool mono: Plasmoid.configuration.iconColor === "monochrome"
    readonly property bool showHidden: Plasmoid.configuration.showHidden
    readonly property bool everything: Plasmoid.configuration.readAllScope === "everything"
    readonly property var rows: {
        const out = root.shown.map(i => ({ item: i, dimmed: false, first: false }))
        if (showHidden) root.hidden.forEach((i, n) => out.push({ item: i, dimmed: true, first: n === 0 }))
        return out
    }

    Layout.minimumWidth: Kirigami.Units.gridUnit * 20
    Layout.preferredWidth: Kirigami.Units.gridUnit * 24
    Layout.minimumHeight: Kirigami.Units.gridUnit * 12
    Layout.preferredHeight: Kirigami.Units.gridUnit * 28
    collapseMarginsHint: true

    header: PlasmaExtras.PlasmoidHeading {
        RowLayout {
            anchors.fill: parent
            spacing: Kirigami.Units.smallSpacing

            Logo {
                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                Layout.preferredHeight: Kirigami.Units.iconSizes.small
                Layout.leftMargin: Kirigami.Units.smallSpacing
                orange: popup.mono ? Kirigami.Theme.textColor : root.forgejoOrange
                red: popup.mono ? Kirigami.Theme.textColor : root.forgejoRed
            }
            Kirigami.Heading {
                level: 4
                text: i18n("Notifications")
            }
            Rectangle {
                visible: root.badgeCount > 0
                radius: height / 2
                color: popup.mono ? Kirigami.Theme.disabledTextColor : Kirigami.Theme.negativeTextColor
                implicitWidth: Math.max(implicitHeight, countLabel.implicitWidth + Kirigami.Units.smallSpacing * 2)
                implicitHeight: countLabel.implicitHeight + 2
                PlasmaComponents.Label {
                    id: countLabel
                    anchors.centerIn: parent
                    text: root.badgeCount
                    color: "white"
                    font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                    font.weight: Font.Bold
                    font.features: { "tnum": 1 }
                }
            }
            Item { Layout.fillWidth: true }
            PlasmaComponents.ToolButton {
                text: i18n("Read all")
                icon.name: "mail-mark-read"
                display: QQC2.AbstractButton.TextBesideIcon
                enabled: root.canReadAll
                onClicked: root.readAll()
                PlasmaComponents.ToolTip {
                    text: popup.everything
                        ? i18n("Mark every unread notification as read, including ones your filters hide")
                        : i18n("Mark the notifications in this list as read")
                }
            }
            PlasmaComponents.BusyIndicator {
                visible: root.refreshing
                running: visible
                Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
                Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
            }
            PlasmaComponents.ToolButton {
                visible: !root.refreshing
                icon.name: "view-refresh"
                onClicked: root.refresh(true)
                PlasmaComponents.ToolTip { text: i18n("Refresh now") }
            }
            PlasmaComponents.ToolButton {
                icon.name: "configure"
                onClicked: Plasmoid.internalAction("configure").trigger()
                PlasmaComponents.ToolTip { text: i18n("Settings") }
            }
        }
    }

    footer: PlasmaExtras.PlasmoidHeading {
        position: PlasmaComponents.ToolBar.Footer
        visible: root.lastFetched > 0
        RowLayout {
            anchors.fill: parent
            spacing: Kirigami.Units.smallSpacing

            PlasmaComponents.ToolButton {
                visible: root.hidden.length > 0
                text: popup.showHidden ? i18n("Hide filtered") : i18np("%1 filtered", "%1 filtered", root.hidden.length)
                icon.name: popup.showHidden ? "view-hidden" : "view-filter"
                font: Kirigami.Theme.smallFont
                onClicked: Plasmoid.configuration.showHidden = !popup.showHidden
                PlasmaComponents.ToolTip { text: i18n("Notifications your filters hide. They don't count toward the badge.") }
            }
            PlasmaComponents.BusyIndicator {
                visible: root.hidden.length === 0 && root.enriching
                running: visible
                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                Layout.preferredHeight: Kirigami.Units.iconSizes.small
            }
            PlasmaComponents.Label {
                visible: root.hidden.length === 0
                text: root.enriching ? i18n("Applying filters…") : i18n("Updated %1", F.ago(root.lastFetched, root.now))
                font: Kirigami.Theme.smallFont
                opacity: 0.7
            }
            Item { Layout.fillWidth: true }
            PlasmaComponents.ToolButton {
                text: i18n("Open Forgejo")
                icon.name: "internet-web-browser"
                font: Kirigami.Theme.smallFont
                enabled: root.serverURL !== ""
                onClicked: { root.openWeb(); root.expanded = false }
            }
        }
    }

    // First load, or nothing to show.
    PlasmaExtras.PlaceholderMessage {
        anchors.centerIn: parent
        width: parent.width - Kirigami.Units.gridUnit * 2
        visible: list.count === 0
        iconName: root.lastFetched === 0
            ? (root.error ? root.error.icon : "view-refresh")
            : "checkmark"
        text: root.lastFetched === 0
            ? (root.error ? root.error.title : i18n("Loading notifications…"))
            : i18n("You're all caught up")
        explanation: root.lastFetched === 0
            ? (root.error ? root.error.message : "")
            : [root.hidden.length ? i18np("%1 hidden by your filters", "%1 hidden by your filters", root.hidden.length) : "",
               root.error ? root.error.title + ". " + root.error.message : ""].filter(s => s).join("\n")
        helpfulAction: root.lastFetched === 0 && root.error
            ? (root.error.kind === "notConfigured" ? settingsAction : retryAction) : null
        QQC2.Action {
            id: retryAction
            text: i18n("Try Again")
            icon.name: "view-refresh"
            onTriggered: root.refresh(true)
        }
        QQC2.Action {
            id: settingsAction
            text: i18n("Settings…")
            icon.name: "configure"
            onTriggered: Plasmoid.internalAction("configure").trigger()
        }
    }

    PlasmaComponents.ScrollView {
        anchors.fill: parent
        visible: list.count > 0
        opacity: root.stale ? 0.6 : 1

        ListView {
            id: list
            model: popup.rows
            clip: true
            reuseItems: true
            boundsBehavior: Flickable.StopAtBounds

            header: ErrorLine {
                width: ListView.view.width
                visible: root.error !== null
                height: visible ? implicitHeight : 0
            }

            delegate: NotificationRow {
                required property var modelData
                width: ListView.view.width
                item: modelData.item
                dimmed: modelData.dimmed
                sectionTitle: modelData.first ? i18n("Hidden by filters") : ""
            }
        }
    }

    component ErrorLine: RowLayout {
        spacing: Kirigami.Units.smallSpacing
        Kirigami.Icon {
            source: "dialog-warning"
            color: Kirigami.Theme.neutralTextColor
            Layout.preferredWidth: Kirigami.Units.iconSizes.small
            Layout.preferredHeight: Kirigami.Units.iconSizes.small
            Layout.leftMargin: Kirigami.Units.largeSpacing
            Layout.alignment: Qt.AlignTop
            Layout.topMargin: Kirigami.Units.smallSpacing
        }
        PlasmaComponents.Label {
            Layout.fillWidth: true
            Layout.rightMargin: Kirigami.Units.largeSpacing
            Layout.topMargin: Kirigami.Units.smallSpacing
            Layout.bottomMargin: Kirigami.Units.smallSpacing
            wrapMode: Text.WordWrap
            font: Kirigami.Theme.smallFont
            opacity: 0.8
            text: root.error ? root.error.title + ". " + root.error.message : ""
        }
    }
}
