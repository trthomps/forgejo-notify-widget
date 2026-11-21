import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM

import "../code/forgejo.js" as F

KCM.SimpleKCM {
    id: page

    property string cfg_authMode
    property string cfg_teaLogin
    property string cfg_teaPath
    property string cfg_serverURL

    property var teaLogins: []
    property bool teaLoaded: false
    property string status: ""
    property bool statusOK: false
    property bool checking: false
    readonly property string server: F.normalizeServer(cfg_serverURL) || ""
    property var checkXHR: null
    property int checkSeq: 0

    Timer {
        // Covers both a hung token lookup and a server that never answers.
        id: checkTimeout
        interval: 30000
        onTriggered: {
            if (page.checkXHR) page.checkXHR.abort()
            page.checkXHR = null
            page.checkSeq += 1
            page.status = i18n("Timed out. Check the server address and your network.")
            page.statusOK = false
            page.checking = false
        }
    }

    Shell {
        id: shell
        teaPath: page.cfg_teaPath
    }

    function loadTeaLogins() {
        shell.readTeaLogins().then(logins => {
            teaLogins = logins
            teaLoaded = true
        })
    }

    Component.onCompleted: loadTeaLogins()

    /// Gets a token the same way the widget does, then asks the server who it belongs to.
    function check() {
        checking = true
        status = ""
        const seq = ++checkSeq
        checkTimeout.restart()
        const fail = message => {
            if (seq !== checkSeq) return
            checkTimeout.stop()
            status = message
            statusOK = false
            checking = false
        }
        let tokenPromise
        let base
        let oauth = false
        if (cfg_authMode === "token") {
            base = server
            if (!base) { fail(i18n("Enter your Forgejo server's address.")); return }
            tokenPromise = shell.run(shell.secretLookupCommand(base)).then(r => r.code === 0 ? r.stdout.trim() : "")
        } else {
            const login = F.pickTeaLogin(teaLogins, cfg_teaLogin)
            if (!login) { fail(i18n("No tea logins found. Run “tea login add” first.")); return }
            base = F.normalizeServer(login.url)
            oauth = login.isOAuth
            tokenPromise = login.token ? Promise.resolve(login.token) : shell.teaHelperToken(login)
        }
        tokenPromise.then(token => {
            if (seq !== checkSeq) return
            if (!token) {
                fail(cfg_authMode === "token" ? i18n("No token stored for %1 yet. Run the command above.", base)
                                              : i18n("tea didn't return a token. Is tea installed, and does “tea login list” show this login?"))
                return
            }
            const xhr = new XMLHttpRequest()
            checkXHR = xhr
            xhr.onreadystatechange = () => {
                if (xhr.readyState !== XMLHttpRequest.DONE || seq !== checkSeq) return
                checkXHR = null
                if (xhr.status === 200) {
                    try {
                        const login = JSON.parse(xhr.responseText).login
                        checkTimeout.stop()
                        status = i18n("Signed in to %1 as %2.", base, login)
                        statusOK = true
                        checking = false
                    } catch (e) { fail(i18n("Unexpected response from %1.", base)) }
                } else {
                    const info = F.errorInfo(F.errorForStatus(xhr.status, xhr.responseText))
                    fail(info.title + ". " + info.message)
                }
            }
            xhr.open("GET", base + "/api/v1/user")
            xhr.setRequestHeader("Authorization", (oauth ? "Bearer " : "token ") + token)
            xhr.setRequestHeader("Accept", "application/json")
            xhr.send()
        })
    }

    Kirigami.FormLayout {
        QQC2.ComboBox {
            Kirigami.FormData.label: i18n("Sign in with:")
            textRole: "text"
            valueRole: "value"
            model: [
                { value: "tea", text: i18n("tea login") },
                { value: "token", text: i18n("Access token") }
            ]
            Component.onCompleted: currentIndex = Math.max(0, indexOfValue(page.cfg_authMode))
            onActivated: { page.cfg_authMode = currentValue; page.status = "" }
        }

        // MARK: tea

        QQC2.ComboBox {
            id: loginBox
            visible: page.cfg_authMode === "tea"
            Kirigami.FormData.label: i18n("Login:")
            enabled: page.teaLogins.length > 0
            textRole: "text"
            valueRole: "value"
            model: [{ value: "", text: i18n("tea's default") }].concat(page.teaLogins.map(l => ({
                value: l.name, text: l.name + (l.name !== l.url.replace(/^https?:\/\//, "") ? " — " + l.url : "")
                    + (l.isDefault ? i18n(" (default)") : "")
            })))
            onModelChanged: currentIndex = Math.max(0, indexOfValue(page.cfg_teaLogin))
            onActivated: { page.cfg_teaLogin = currentValue; page.status = "" }
        }

        QQC2.Label {
            visible: page.cfg_authMode === "tea" && page.teaLoaded && page.teaLogins.length === 0
            Layout.maximumWidth: Kirigami.Units.gridUnit * 22
            wrapMode: Text.WordWrap
            color: Kirigami.Theme.neutralTextColor
            text: i18n("No logins in ~/.config/tea/config.yml. Run “tea login add” in a terminal.")
        }

        RowLayout {
            visible: page.cfg_authMode === "tea"
            Kirigami.FormData.label: i18n("tea binary:")
            QQC2.TextField {
                Layout.preferredWidth: Kirigami.Units.gridUnit * 14
                placeholderText: i18n("Automatic")
                text: page.cfg_teaPath
                onEditingFinished: { page.cfg_teaPath = text.trim(); page.loadTeaLogins() }
            }
        }

        QQC2.Label {
            visible: page.cfg_authMode === "tea"
            Layout.maximumWidth: Kirigami.Units.gridUnit * 22
            wrapMode: Text.WordWrap
            opacity: 0.7
            font: Kirigami.Theme.smallFont
            text: i18n("Read-only: the widget never changes tea's config. Tokens come from tea itself (“tea login helper get”, the same way git gets them). For OAuth logins, when the token expires the widget runs “tea whoami” so tea refreshes its own token.")
        }

        // MARK: Access token

        QQC2.TextField {
            visible: page.cfg_authMode === "token"
            Kirigami.FormData.label: i18n("Server:")
            Layout.preferredWidth: Kirigami.Units.gridUnit * 16
            placeholderText: "https://codeberg.org"
            text: page.cfg_serverURL
            onTextEdited: { page.cfg_serverURL = text.trim(); page.status = "" }
        }

        QQC2.Label {
            visible: page.cfg_authMode === "token"
            Layout.maximumWidth: Kirigami.Units.gridUnit * 22
            wrapMode: Text.WordWrap
            text: i18n("Create a token on your server under Settings → Applications with read:notification, write:notification, read:issue, read:repository and read:user. Then store it in your keyring by running this in a terminal (it asks for the token, so it never lands in your shell history):")
        }

        RowLayout {
            visible: page.cfg_authMode === "token"
            Layout.maximumWidth: Kirigami.Units.gridUnit * 22
            QQC2.TextField {
                id: storeCommand
                Layout.fillWidth: true
                readOnly: true
                font.family: "monospace"
                text: page.server ? shell.secretStoreCommand(page.server) : i18n("Enter the server first")
                enabled: page.server !== ""
            }
            QQC2.Button {
                icon.name: "edit-copy"
                enabled: page.server !== ""
                onClicked: { storeCommand.selectAll(); storeCommand.copy(); storeCommand.deselect() }
                QQC2.ToolTip.text: i18n("Copy")
                QQC2.ToolTip.visible: hovered
            }
        }

        Kirigami.Separator { Kirigami.FormData.isSection: true }

        RowLayout {
            QQC2.Button {
                text: i18n("Check Sign-in")
                icon.name: "dialog-ok-apply"
                enabled: !page.checking
                onClicked: page.check()
            }
            QQC2.BusyIndicator {
                visible: page.checking
                running: visible
                Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
                Layout.preferredWidth: Layout.preferredHeight
            }
        }

        QQC2.Label {
            visible: page.status !== ""
            Layout.maximumWidth: Kirigami.Units.gridUnit * 22
            wrapMode: Text.WordWrap
            color: page.statusOK ? Kirigami.Theme.positiveTextColor : Kirigami.Theme.negativeTextColor
            text: page.status
        }
    }
}
