# Forgejo Notifications

Your Forgejo notifications at a glance: the Forgejo logo with an unread badge, a click-through list, "Read all", and filters that turn the default firehose into what you actually care about. It comes in two versions with the same features and design:

- **macOS**: a menu bar app (Swift, in `Sources/`).
- **KDE Plasma 6 on Linux**: a panel or system tray widget that also works on the desktop (QML, in [`kde/`](kde/README.md)). See [KDE Plasma](#kde-plasma).

![Menu bar styles, light](docs/menubar-light.png)
![Menu bar styles, dark](docs/menubar-dark.png)

## Install

### macOS

Requires macOS 14+ and the Xcode Command Line Tools (`xcode-select --install`).

```sh
make install      # builds "Forgejo Notifications.app", copies it to ~/Applications, launches it
```

`make app` builds into `build/` without installing. Opening the app again (Spotlight, Finder) brings up Settings, which helps when a menu bar manager has hidden the item.

### KDE Plasma (Linux)

Requires Plasma 6. For the default sign-in, [tea](https://gitea.com/gitea/tea) with a login (`tea login add`).

```sh
make kde-install  # installs the widget for your user with kpackagetool6
```

Then right-click a panel or the desktop → **Add Widgets…** → **Forgejo Notifications**. More in [KDE Plasma](#kde-plasma) below.

## Using it on macOS

- **Click** the icon for the list. Click a notification to open it in your browser: the latest comment if there is one, otherwise the issue, PR, commit or repo. It's marked read when you open it (you can turn that off).
- **Hover** a row and click ✓ to mark just that one read.
- **Read all** sits in the popover header. By default it clears everything unread on the server, including filtered-out items. Settings → Filters → *Read all marks* can limit it to the shown list.
- **Right-click** the icon for Refresh, Mark All as Read, Open in Browser, Settings and Quit.
- **Terminal**: `ForgejoNotify --print` lists what the menu bar would show, with your filters applied.

## Signing in on macOS

Settings → Account offers three options:

| Mode | How it works |
| --- | --- |
| **tea login** (default) | Reads `~/Library/Application Support/tea/config.yml` (or `~/.config/tea/`, or `$XDG_CONFIG_HOME/tea/`). Read-only. For logins made with `tea login add --oauth`, the app never refreshes tea's token itself, because that would rotate the refresh token out from under tea. When the token expires, it runs `tea whoami` so tea refreshes its own token, then re-reads the config. |
| **OAuth** | Browser sign-in using the authorization code flow with PKCE and a loopback redirect (`http://127.0.0.1:<random port>`). It goes through your normal Forgejo login page, so SSO and 2FA work. The default client ID is Forgejo's built-in `git-credential-oauth` app. To use your own app instead, create one under Settings → Applications → OAuth2 with *Confidential client* unchecked and redirect URI `http://127.0.0.1`, then paste its client ID. Tokens are stored in the Keychain and refreshed automatically. |
| **Access token** | Paste a token with `read:notification`, `write:notification`, `read:issue`, `read:repository` and `read:user`. Stored in the Keychain. |

Secrets go into the login Keychain through `/usr/bin/security`, piped over stdin, so they never appear in a process listing. Reading them back doesn't prompt, even after a rebuild re-signs the app.

## Filters

The same in both versions. Settings → Filters (Configure… → Filters on KDE) decides what shows in the list and counts toward the badge. Your notifications on the server don't change, unless you turn on auto-read.

- **Kinds**: issues, pull requests, commits, releases. You can also hide closed issues, merged PRs and draft PRs.
- **Only things I'm involved in**: you opened it, are assigned, are a requested reviewer, or are @mentioned in the latest comment.
- **Repositories**: an allow-list and/or a block-list. One-click "hide" buttons appear for the repos filling your inbox.
- **Hide authors**, **hide when the last comment is by**, **hide labels**, **hide titles containing**: comma-separated and case-insensitive, with `*` globs (`renovate, *bot`, `chore(deps)*`).
- **Automatically mark filtered-out notifications as read**: off by default.

Author, label, draft, comment and involvement filters need the issue or PR itself. The app looks each one up once and caches it until the thread changes (`~/Library/Application Support/ForgejoNotify/enrichment.json` on macOS, the widget's own config entry on KDE). The popover footer shows how many items are hidden, and you can expand them inline.

## Menu bar options

- Icon: Forgejo colors or monochrome. Monochrome follows the menu bar's light/dark text color.
- Unread count: badge, number next to the logo, dot, or none.
- The icon dims when nothing is unread (optional) and while loading. An orange dot means an error; the popover explains it.
- Optional macOS banners for new items that pass your filters. Clicking a banner opens the item.

## KDE Plasma

The Plasma widget is a port of the macOS app: the same list, badge styles, Read all and filters, drawn with Plasma's own theme.

| Panel icon styles | Popup |
| --- | --- |
| ![Panel icon styles](docs/kde-panel.png) | ![Popup](docs/kde-popup.png) |

- **In a panel or the system tray**: the logo with a badge, a number, a dot, or nothing, in Forgejo colors or monochrome. **Click** for the list, **middle-click** to refresh, **right-click** for Refresh Now, Mark All as Read, Open Notifications in Browser and Configure.
- **In the list**: click a notification to open it, hover and click ✓ to mark it read. **Right-click** a row to copy its link or hide its repository.
- **On the desktop**: the list itself. Resize and move it like any Plasma widget.
- **Settings** (right-click → Configure): appearance and behavior, account, and the same filters as the macOS app. The Filters page has one-click Hide buttons for your busiest repositories.

Signing in is a little different from the macOS app:

- **tea login** (default): recent tea versions keep tokens in their own encrypted store rather than `config.yml`, so the widget asks tea for the token with `tea login helper get`, the same way git does. As on macOS, it never writes tea's config or refreshes tea's OAuth token itself.
- **Access token**: stored in your keyring (KWallet or GNOME Keyring) with `secret-tool`. Settings shows the command to run.
- **No OAuth browser sign-in**: a Plasma widget can't listen for the redirect. `tea login add --oauth` plus tea mode gets you the same result.

Desktop notifications go through Plasma's notification system. After upgrading, restart Plasma to load the new version (`systemctl --user restart plasma-plasmashell`). `make kde-uninstall` removes it. Details are in [`kde/README.md`](kde/README.md).

## Development

```sh
swift build
swift run ForgejoNotify --print                 # live list in the terminal
swift run ForgejoNotify --render-previews docs  # regenerate the images above
FORGEJO_NOTIFY_DEBUG=1 "build/Forgejo Notifications.app/Contents/MacOS/ForgejoNotify"   # log requests
```

| File | What's in it |
| --- | --- |
| `ForgejoAPI.swift` | REST calls: list, mark read, mark all, issue/PR/comment lookups |
| `Auth.swift` | tea config reader, Keychain, OAuth PKCE + loopback listener, credential renewal |
| `Filters.swift` | Filter rules and glob matching |
| `NotificationStore.swift` | Polling, enrichment cache, optimistic reads |
| `Logo.swift` | Forgejo logo (drawn from its SVG geometry), menu bar renderer, app icon |
| `StatusItemController.swift`, `PopoverView.swift`, `SettingsView.swift` | UI |

The KDE widget lives in `kde/package` (a standard Plasma applet package). Its parsing and filter logic in `kde/package/contents/code/forgejo.js` mirrors `Models.swift`, `Filters.swift` and the tea config reader in `Auth.swift`, so a change to one usually needs the same change in the other. `make kde-test` runs its tests under Node. [`kde/README.md`](kde/README.md) has the file map.

## License

[MIT](LICENSE). The Forgejo logo belongs to the Forgejo project and is not covered by this license.
