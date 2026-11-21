import AppKit
import SwiftUI

enum IconColor: String, CaseIterable, Identifiable {
    case color, monochrome
    var id: String { rawValue }
    var title: String { self == .color ? "Forgejo colors" : "Monochrome" }
}

enum BadgeStyle: String, CaseIterable, Identifiable {
    case badge, number, dot, none
    var id: String { rawValue }
    var title: String {
        switch self {
        case .badge: "Badge"
        case .number: "Number"
        case .dot: "Dot"
        case .none: "None"
        }
    }
}

enum ReadAllScope: String, CaseIterable, Identifiable {
    case everything, shown
    var id: String { rawValue }
    var title: String {
        switch self {
        case .everything: "Everything unread, including filtered-out"
        case .shown: "Only the notifications shown in the list"
        }
    }
}

enum PrefKey {
    static let authMode = "authMode"
    static let teaLogin = "teaLogin"
    static let serverURL = "serverURL"
    static let oauthClientID = "oauthClientID"

    static let iconColor = "iconColor"
    static let badgeStyle = "badgeStyle"
    static let hideWhenEmpty = "dimWhenEmpty"
    static let refreshInterval = "refreshInterval"
    static let markReadOnOpen = "markReadOnOpen"
    static let systemNotifications = "systemNotifications"
    static let readAllScope = "readAllScope"

    static let types = "filterTypes"
    static let hideClosed = "filterHideClosed"
    static let hideMerged = "filterHideMerged"
    static let hideDrafts = "filterHideDrafts"
    static let onlyInvolved = "filterOnlyInvolved"
    static let includeRepos = "filterIncludeRepos"
    static let excludeRepos = "filterExcludeRepos"
    static let excludeAuthors = "filterExcludeAuthors"
    static let excludeCommenters = "filterExcludeCommenters"
    static let excludeLabels = "filterExcludeLabels"
    static let excludeTitles = "filterExcludeTitles"
    static let autoReadFiltered = "filterAutoRead"
    static let showHidden = "showHiddenInList"
}

/// Typed access to UserDefaults. SwiftUI binds to the same keys with @AppStorage.
enum Prefs {
    static var store: UserDefaults { .standard }
    static let allTypes = SubjectType.allCases.map(\.rawValue).joined(separator: ",")

    static func registerDefaults() {
        store.register(defaults: [
            PrefKey.authMode: AuthMode.tea.rawValue,
            PrefKey.teaLogin: "",
            PrefKey.serverURL: "",
            PrefKey.oauthClientID: OAuthFlow.defaultClientID,
            PrefKey.iconColor: IconColor.color.rawValue,
            PrefKey.badgeStyle: BadgeStyle.badge.rawValue,
            PrefKey.hideWhenEmpty: true,
            PrefKey.refreshInterval: 60.0,
            PrefKey.markReadOnOpen: true,
            PrefKey.systemNotifications: false,
            PrefKey.readAllScope: ReadAllScope.everything.rawValue,
            PrefKey.types: allTypes,
            PrefKey.hideClosed: false,
            PrefKey.hideMerged: false,
            PrefKey.hideDrafts: false,
            PrefKey.onlyInvolved: false,
            PrefKey.includeRepos: "",
            PrefKey.excludeRepos: "",
            PrefKey.excludeAuthors: "",
            PrefKey.excludeCommenters: "",
            PrefKey.excludeLabels: "",
            PrefKey.excludeTitles: "",
            PrefKey.autoReadFiltered: false,
            PrefKey.showHidden: false,
        ])
    }

    static var authMode: AuthMode { AuthMode(rawValue: store.string(forKey: PrefKey.authMode) ?? "") ?? .tea }
    static var teaLogin: String { store.string(forKey: PrefKey.teaLogin) ?? "" }
    static var serverURL: String { store.string(forKey: PrefKey.serverURL) ?? "" }
    static var oauthClientID: String {
        (store.string(forKey: PrefKey.oauthClientID) ?? "").trimmingCharacters(in: .whitespaces).nonEmpty
            ?? OAuthFlow.defaultClientID
    }

    static var iconColor: IconColor { IconColor(rawValue: store.string(forKey: PrefKey.iconColor) ?? "") ?? .color }
    static var badgeStyle: BadgeStyle { BadgeStyle(rawValue: store.string(forKey: PrefKey.badgeStyle) ?? "") ?? .badge }
    static var dimWhenEmpty: Bool { store.bool(forKey: PrefKey.hideWhenEmpty) }
    static var refreshInterval: TimeInterval { max(30, store.double(forKey: PrefKey.refreshInterval)) }
    static var markReadOnOpen: Bool { store.bool(forKey: PrefKey.markReadOnOpen) }
    static var systemNotifications: Bool { store.bool(forKey: PrefKey.systemNotifications) }
    static var readAllScope: ReadAllScope {
        ReadAllScope(rawValue: store.string(forKey: PrefKey.readAllScope) ?? "") ?? .everything
    }
    static var autoReadFiltered: Bool { store.bool(forKey: PrefKey.autoReadFiltered) }

    static var filters: FilterSettings {
        FilterSettings(
            types: Set((store.string(forKey: PrefKey.types) ?? allTypes).split(separator: ",").compactMap {
                SubjectType(rawValue: String($0))
            }),
            hideClosed: store.bool(forKey: PrefKey.hideClosed),
            hideMerged: store.bool(forKey: PrefKey.hideMerged),
            hideDrafts: store.bool(forKey: PrefKey.hideDrafts),
            onlyInvolved: store.bool(forKey: PrefKey.onlyInvolved),
            includeRepos: patterns(PrefKey.includeRepos),
            excludeRepos: patterns(PrefKey.excludeRepos),
            excludeAuthors: patterns(PrefKey.excludeAuthors),
            excludeCommenters: patterns(PrefKey.excludeCommenters),
            excludeLabels: patterns(PrefKey.excludeLabels),
            excludeTitles: patterns(PrefKey.excludeTitles)
        )
    }

    /// Comma- or newline-separated list.
    static func patterns(_ key: String) -> [String] {
        (store.string(forKey: key) ?? "")
            .split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

extension NSColor {
    static let forgejoOrange = NSColor(srgbRed: 1.0, green: 0.4, blue: 0.0, alpha: 1)    // #ff6600
    static let forgejoRed = NSColor(srgbRed: 0.831, green: 0.0, blue: 0.0, alpha: 1)     // #d40000
}

extension Color {
    static let forgejoOrange = Color(nsColor: .forgejoOrange)
    static let forgejoRed = Color(nsColor: .forgejoRed)
}
