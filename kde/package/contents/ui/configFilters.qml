import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM

import "../code/forgejo.js" as F

KCM.SimpleKCM {
    id: page

    property string cfg_filterTypes
    property bool cfg_filterHideClosed
    property bool cfg_filterHideMerged
    property bool cfg_filterHideDrafts
    property bool cfg_filterOnlyInvolved
    property string cfg_filterIncludeRepos
    property string cfg_filterExcludeRepos
    property string cfg_filterExcludeAuthors
    property string cfg_filterExcludeCommenters
    property string cfg_filterExcludeLabels
    property string cfg_filterExcludeTitles
    property bool cfg_filterAutoRead
    property string cfg_busyRepos

    readonly property var types: F.patterns(cfg_filterTypes)
    readonly property var busy: { try { return JSON.parse(cfg_busyRepos || "[]") } catch (e) { return [] } }
    readonly property var excluded: F.patterns(cfg_filterExcludeRepos)

    function setType(type, on) {
        const list = F.TYPES.filter(t => t === type ? on : types.indexOf(t) >= 0)
        cfg_filterTypes = list.join(",")
    }

    component TypeBox: QQC2.CheckBox {
        required property string type
        text: F.typeTitles[type]
        checked: page.types.indexOf(type) >= 0
        onToggled: page.setType(type, checked)
    }

    component PatternField: QQC2.TextField {
        Layout.preferredWidth: Kirigami.Units.gridUnit * 18
    }

    Kirigami.FormLayout {
        TypeBox { Kirigami.FormData.label: i18n("Show:"); type: "Issue" }
        TypeBox { type: "Pull" }
        TypeBox { type: "Commit" }
        TypeBox { type: "Repository" }
        TypeBox { type: "Other" }

        QQC2.CheckBox {
            Kirigami.FormData.label: i18n("Hide:")
            text: i18n("Closed issues")
            checked: page.cfg_filterHideClosed
            onToggled: page.cfg_filterHideClosed = checked
        }
        QQC2.CheckBox {
            text: i18n("Merged pull requests")
            checked: page.cfg_filterHideMerged
            onToggled: page.cfg_filterHideMerged = checked
        }
        QQC2.CheckBox {
            text: i18n("Draft pull requests")
            checked: page.cfg_filterHideDrafts
            onToggled: page.cfg_filterHideDrafts = checked
        }

        QQC2.CheckBox {
            Kirigami.FormData.label: i18n("Involvement:")
            text: i18n("Only things I'm involved in")
            checked: page.cfg_filterOnlyInvolved
            onToggled: page.cfg_filterOnlyInvolved = checked
        }
        QQC2.Label {
            Layout.maximumWidth: Kirigami.Units.gridUnit * 20
            wrapMode: Text.WordWrap
            opacity: 0.7
            font: Kirigami.Theme.smallFont
            text: i18n("You opened it, are assigned, are a requested reviewer, or are @mentioned in the latest comment.")
        }

        Kirigami.Separator { Kirigami.FormData.isSection: true; Kirigami.FormData.label: i18n("Repositories") }

        PatternField {
            Kirigami.FormData.label: i18n("Only these:")
            placeholderText: i18n("Any repository")
            text: page.cfg_filterIncludeRepos
            onTextEdited: page.cfg_filterIncludeRepos = text
        }
        PatternField {
            Kirigami.FormData.label: i18n("Never these:")
            placeholderText: "travis/archive, *-mirror"
            text: page.cfg_filterExcludeRepos
            onTextEdited: page.cfg_filterExcludeRepos = text
        }
        Flow {
            visible: page.busy.length > 0
            Kirigami.FormData.label: i18n("Busiest:")
            Layout.maximumWidth: Kirigami.Units.gridUnit * 20
            spacing: Kirigami.Units.smallSpacing
            Repeater {
                model: page.busy
                QQC2.Button {
                    readonly property bool hidden: page.excluded.indexOf(modelData.repo) >= 0
                    text: (hidden ? i18n("Hidden: ") : i18n("Hide ")) + modelData.repo + " (" + modelData.count + ")"
                    icon.name: hidden ? "view-hidden" : "list-remove"
                    enabled: !hidden
                    onClicked: {
                        const list = page.excluded.concat([modelData.repo])
                        page.cfg_filterExcludeRepos = list.join(", ")
                    }
                }
            }
        }

        Kirigami.Separator { Kirigami.FormData.isSection: true; Kirigami.FormData.label: i18n("Hide when…") }

        PatternField {
            Kirigami.FormData.label: i18n("Author is:")
            placeholderText: "renovate, *bot"
            text: page.cfg_filterExcludeAuthors
            onTextEdited: page.cfg_filterExcludeAuthors = text
        }
        PatternField {
            Kirigami.FormData.label: i18n("Last comment by:")
            placeholderText: "ci, *bot"
            text: page.cfg_filterExcludeCommenters
            onTextEdited: page.cfg_filterExcludeCommenters = text
        }
        PatternField {
            Kirigami.FormData.label: i18n("Has label:")
            placeholderText: "dependencies, wontfix"
            text: page.cfg_filterExcludeLabels
            onTextEdited: page.cfg_filterExcludeLabels = text
        }
        PatternField {
            Kirigami.FormData.label: i18n("Title contains:")
            placeholderText: "chore(deps)*"
            text: page.cfg_filterExcludeTitles
            onTextEdited: page.cfg_filterExcludeTitles = text
        }
        QQC2.Label {
            Layout.maximumWidth: Kirigami.Units.gridUnit * 20
            wrapMode: Text.WordWrap
            opacity: 0.7
            font: Kirigami.Theme.smallFont
            text: i18n("Comma-separated and case-insensitive, with * globs. Author, label, draft, comment and involvement filters look up each issue or PR once and cache it until the thread changes.")
        }

        Kirigami.Separator { Kirigami.FormData.isSection: true }

        QQC2.CheckBox {
            Kirigami.FormData.label: i18n("Filtered-out:")
            text: i18n("Mark them as read on the server automatically")
            checked: page.cfg_filterAutoRead
            onToggled: page.cfg_filterAutoRead = checked
        }
        QQC2.Label {
            Layout.maximumWidth: Kirigami.Units.gridUnit * 20
            wrapMode: Text.WordWrap
            opacity: 0.7
            font: Kirigami.Theme.smallFont
            text: i18n("Otherwise filters only change what the widget shows. Your notifications on the server stay as they are.")
        }
    }
}
