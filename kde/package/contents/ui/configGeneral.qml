import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM

KCM.SimpleKCM {
    id: page

    property string cfg_iconColor
    property string cfg_badgeStyle
    property bool cfg_dimWhenEmpty
    property int cfg_refreshInterval
    property bool cfg_markReadOnOpen
    property bool cfg_systemNotifications
    property string cfg_readAllScope

    Kirigami.FormLayout {
        QQC2.ComboBox {
            Kirigami.FormData.label: i18n("Icon:")
            textRole: "text"
            valueRole: "value"
            model: [
                { value: "color", text: i18n("Forgejo colors") },
                { value: "monochrome", text: i18n("Monochrome (follows the panel's text color)") }
            ]
            Component.onCompleted: currentIndex = Math.max(0, indexOfValue(page.cfg_iconColor))
            onActivated: page.cfg_iconColor = currentValue
        }

        QQC2.ComboBox {
            Kirigami.FormData.label: i18n("Unread count:")
            textRole: "text"
            valueRole: "value"
            model: [
                { value: "badge", text: i18n("Badge on the logo") },
                { value: "number", text: i18n("Number next to the logo") },
                { value: "dot", text: i18n("Dot") },
                { value: "none", text: i18n("None") }
            ]
            Component.onCompleted: currentIndex = Math.max(0, indexOfValue(page.cfg_badgeStyle))
            onActivated: page.cfg_badgeStyle = currentValue
        }

        QQC2.CheckBox {
            text: i18n("Dim the icon when nothing is unread")
            checked: page.cfg_dimWhenEmpty
            onToggled: page.cfg_dimWhenEmpty = checked
        }

        Kirigami.Separator { Kirigami.FormData.isSection: true }

        QQC2.ComboBox {
            Kirigami.FormData.label: i18n("Check every:")
            textRole: "text"
            valueRole: "value"
            model: [
                { value: 30, text: i18n("30 seconds") },
                { value: 60, text: i18n("1 minute") },
                { value: 120, text: i18n("2 minutes") },
                { value: 300, text: i18n("5 minutes") },
                { value: 900, text: i18n("15 minutes") }
            ]
            Component.onCompleted: {
                const i = indexOfValue(page.cfg_refreshInterval)
                currentIndex = i >= 0 ? i : 1
            }
            onActivated: page.cfg_refreshInterval = currentValue
        }

        QQC2.CheckBox {
            Kirigami.FormData.label: i18n("Opening:")
            text: i18n("Mark a notification read when I open it")
            checked: page.cfg_markReadOnOpen
            onToggled: page.cfg_markReadOnOpen = checked
        }

        QQC2.ComboBox {
            Kirigami.FormData.label: i18n("Read all marks:")
            textRole: "text"
            valueRole: "value"
            model: [
                { value: "everything", text: i18n("Everything unread, including filtered-out") },
                { value: "shown", text: i18n("Only the notifications shown in the list") }
            ]
            Component.onCompleted: currentIndex = Math.max(0, indexOfValue(page.cfg_readAllScope))
            onActivated: page.cfg_readAllScope = currentValue
        }

        QQC2.CheckBox {
            Kirigami.FormData.label: i18n("Desktop notifications:")
            text: i18n("Show a notification for new items that pass my filters")
            checked: page.cfg_systemNotifications
            onToggled: page.cfg_systemNotifications = checked
        }

        Kirigami.Separator { Kirigami.FormData.isSection: true }

        QQC2.Label {
            Layout.maximumWidth: Kirigami.Units.gridUnit * 22
            wrapMode: Text.WordWrap
            opacity: 0.7
            text: i18n("Middle-click the panel icon to refresh. Right-click a notification to copy its link or hide its repository.")
        }
    }
}
