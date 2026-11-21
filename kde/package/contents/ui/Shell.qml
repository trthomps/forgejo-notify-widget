import QtQuick
import org.kde.plasma.plasma5support as P5Support

import "../code/forgejo.js" as F

// Runs shell commands through Plasma's executable data engine (QML can't read files or spawn
// processes on its own). run() returns a Promise of { code, stdout, stderr }.
P5Support.DataSource {
    id: shell
    engine: "executable"
    connectedSources: []

    /// Path to tea from the settings; empty means "look in PATH and the usual install spots".
    property string teaPath: ""

    property var callbacks: ({})
    property int serial: 0

    onNewData: (source, data) => {
        const cb = callbacks[source]
        delete callbacks[source]
        disconnectSource(source)
        if (cb) cb(data["exit code"], data["stdout"] || "", data["stderr"] || "")
    }

    function run(command) {
        return new Promise(resolve => {
            // A unique trailing comment lets the same command run again while an old one lingers.
            const source = command + " # " + (++serial)
            callbacks[source] = (code, stdout, stderr) => resolve({ code, stdout, stderr })
            connectSource(source)
        })
    }

    readonly property string teaConfigCommand:
        'for f in "${XDG_CONFIG_HOME:-$HOME/.config}/tea/config.yml" "$HOME/.config/tea/config.yml"; do '
        + '[ -r "$f" ] && exec cat "$f"; done; exit 1'

    /// A command that runs tea; `$TEA` in `args` (already shell-quoted) becomes the tea binary.
    function teaCommand(args) {
        return 't=' + F.shellQuote(teaPath) + '; [ -x "$t" ] || t=$(command -v tea 2>/dev/null); '
            + 'for c in "$HOME/.local/bin/tea" "$HOME/go/bin/tea" /home/linuxbrew/.linuxbrew/bin/tea '
            + '/usr/local/bin/tea /usr/bin/tea; do [ -x "$t" ] && break; t="$c"; done; '
            + '[ -x "$t" ] || exit 127; ' + args.replace(/\$TEA/g, '"$t"')
    }

    function readTeaLogins() {
        return run(teaConfigCommand).then(r => r.code === 0 ? F.parseTeaConfig(r.stdout) : [])
    }

    /// tea 0.10+ keeps tokens in its own encrypted store, not config.yml. Ask it the way git does.
    function teaHelperToken(login) {
        const h = F.hostOf(login.url)
        if (!h) return Promise.resolve(null)
        return run(teaCommand("printf 'protocol=%s\\nhost=%s\\n\\n' " + F.shellQuote(h.protocol) + " "
                              + F.shellQuote(h.host) + " | $TEA login helper get --login " + F.shellQuote(login.name)))
            .then(r => r.code === 0 ? F.parseCredentialHelper(r.stdout) : null)
    }

    /// For tea OAuth logins: a harmless tea command makes tea refresh its own token. Best effort.
    function teaNudge(login) {
        return run(teaCommand("timeout 15 $TEA whoami --login " + F.shellQuote(login.name) + " >/dev/null 2>&1"))
    }

    readonly property string secretService: "io.github.trthomps.forgejo-notify"

    function secretLookupCommand(server) {
        return "secret-tool lookup service " + F.shellQuote(secretService) + " account " + F.shellQuote("token:" + server)
    }

    /// For the user to run in a terminal: secret-tool prompts for the token, so it never lands in
    /// shell history or a process listing.
    function secretStoreCommand(server) {
        return "secret-tool store --label=" + F.shellQuote("Forgejo Notifications (" + server + ")")
            + " service " + F.shellQuote(secretService) + " account " + F.shellQuote("token:" + server)
    }
}
