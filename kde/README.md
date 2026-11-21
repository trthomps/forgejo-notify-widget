# Forgejo Notifications for KDE Plasma 6

A Plasma 6 widget (plasmoid) port of the macOS app: the Forgejo logo with an unread badge, a click-through list, Read all, and the same filters, in QML/Qt 6.

- **In a panel or the system tray**: the logo with a badge, a number, a dot, or nothing. Click for the list, middle-click to refresh. Right-click for Refresh Now, Mark All as Read and Open Notifications in Browser.
- **In the list**: click a notification to open it (the latest comment if there is one). Hover and click ✓ to mark one read. Right-click a row to copy its link or hide its repository.
- **On the desktop**: the list itself.

## Install

Requires Plasma 6. For the default sign-in, [tea](https://gitea.com/gitea/tea) with a login (`tea login add`).

```sh
make kde-install    # or: kpackagetool6 -t Plasma/Applet -i kde/package
```

Then right-click a panel or the desktop → **Add Widgets…** → **Forgejo Notifications**. Settings are in the widget's **Configure…** dialog. **Account → Check Sign-in** tests your login.

After upgrading an installed copy, restart Plasma so it reloads the QML: `systemctl --user restart plasma-plasmashell`. To try it in a window without touching your panel: `plasmawindowed dev.forgejonotify.plasmoid`.

## Signing in

| Mode | How it works |
| --- | --- |
| **tea login** (default) | Reads the login list from `$XDG_CONFIG_HOME/tea/config.yml` (or `~/.config/tea/`). Recent tea versions keep tokens in their own encrypted store, so the widget gets the token with `tea login helper get`, the same way git does. A `token:` in `config.yml` (older tea) is used directly. The widget never writes tea's config or refreshes tea's OAuth token itself. When the server rejects the token, the widget runs `tea whoami` so tea refreshes its own token, then asks again. tea is looked up in `PATH`, `~/.local/bin`, `~/go/bin`, Homebrew on Linux, `/usr/local/bin` and `/usr/bin`, or you can set a path. |
| **Access token** | A token with `read:notification`, `write:notification`, `read:issue`, `read:repository` and `read:user`, stored in your keyring (KWallet or GNOME Keyring) through the Secret Service. Settings → Account shows a `secret-tool store …` command to run in a terminal. It prompts for the token, so the token never appears in shell history or a process listing. |

## How it differs from the macOS version

- **No OAuth browser sign-in.** QML can't listen on a loopback port for the redirect. If you need OAuth, use `tea login add --oauth` and the tea mode, which gets you the same result.
- **Tokens stay in memory.** The widget never writes them anywhere.
- **Shell commands** (reading tea's config, `tea`, `secret-tool`) run through Plasma's executable data engine, since QML can't read files or start processes on its own.
- **Cache**: issue and comment lookups for the filters go in the widget's own config entry, in `~/.config/plasma-org.kde.plasma.desktop-appletsrc`. No tokens.
- **Busiest repositories**: the Filters page shows one-click Hide buttons for the repos with the most notifications, as of the last refresh.
- **Desktop notifications** go through Plasma's notification system. Click one to open the item.
- **Colors**: the badge uses the theme's negative (red) color, and the error dot uses its neutral (orange) color. Monochrome follows the panel's text color.
- **Resume from suspend** is detected from a gap between clock ticks and triggers a refresh 5 seconds later. There's no network-change monitor, so after a network drop the widget recovers on the next poll.
- No `--print` CLI.

## Files

| File | What's in it |
| --- | --- |
| `package/contents/code/forgejo.js` | Parsing, filters and glob matching, tea config reader, errors, formatting. A port of `Models.swift`, `Filters.swift`, part of `Auth.swift`, and `Fmt`. |
| `package/contents/ui/main.qml` | State, credentials, fetching, enrichment, optimistic reads, polling, desktop notifications |
| `package/contents/ui/Shell.qml` | Running tea and secret-tool |
| `package/contents/ui/Logo.qml` | The Forgejo mark drawn from its SVG geometry |
| `package/contents/ui/CompactRepresentation.qml` | Panel icon |
| `package/contents/ui/PopupView.qml`, `NotificationRow.qml` | The list |
| `package/contents/ui/config*.qml`, `package/contents/config/main.xml` | Settings |

`make kde-test` runs the parser, filter and formatting tests under Node.
