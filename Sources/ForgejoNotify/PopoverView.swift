import SwiftUI

struct PopoverView: View {
    @ObservedObject var store: NotificationStore
    let actions: AppActions
    @AppStorage(PrefKey.showHidden) private var showHidden = false
    @AppStorage(PrefKey.iconColor) private var iconColor: IconColor = .color
    @AppStorage(PrefKey.readAllScope) private var readAllScope: ReadAllScope = .everything

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)
            Divider()
            content
            Divider()
            footer
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
        .frame(width: 380)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            ForgejoLogoView(monochrome: iconColor == .monochrome)
                .frame(width: 16, height: 16)
            Text("Notifications")
                .font(.system(size: 13, weight: .semibold))
            if store.badgeCount > 0 {
                Text("\(store.badgeCount)")
                    .font(.system(size: 10, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(iconColor == .monochrome ? Color.secondary : Color.red))
            }
            Spacer()
            Button {
                Task { await store.readAll() }
            } label: {
                Label("Read all", systemImage: "checkmark.circle")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .buttonStyle(.borderless)
            .disabled(!canReadAll)
            .help(readAllScope == .everything
                  ? "Mark every unread notification as read, including ones your filters hide"
                  : "Mark the notifications in this list as read")
            IconButton(systemName: "arrow.clockwise", help: "Refresh now", busy: store.isRefreshing) {
                actions.refresh()
            }
            IconButton(systemName: "gearshape", help: "Settings") {
                actions.openSettings()
            }
        }
    }

    private var canReadAll: Bool {
        store.badgeCount > 0 || (readAllScope == .everything && store.hidden.contains { $0.thread.unread })
    }

    // MARK: - List

    @ViewBuilder
    private var content: some View {
        if store.threads.isEmpty && store.lastFetched == nil {
            StatusMessage(error: store.error, retry: actions.refresh, openSettings: actions.openSettings)
                .padding(16)
        } else if store.shown.isEmpty && (!showHidden || store.hidden.isEmpty) {
            VStack(spacing: 8) {
                Image(systemName: "tray")
                    .font(.system(size: 26))
                    .foregroundStyle(.tertiary)
                Text("You're all caught up")
                    .font(.system(size: 13, weight: .semibold))
                if !store.hidden.isEmpty {
                    Text("\(store.hidden.count) hidden by your filters")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                if let error = store.error {
                    ErrorLine(error: error).padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if let error = store.error {
                        ErrorLine(error: error)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                        Divider()
                    }
                    ForEach(store.shown) { item in
                        NotificationRow(item: item, now: store.now,
                                        open: { open(item.thread) },
                                        markRead: { Task { await store.markRead([item.thread]) } })
                        Divider().padding(.leading, 42)
                    }
                    if showHidden && !store.hidden.isEmpty {
                        HStack {
                            Text("Hidden by filters")
                                .font(.system(size: 10.5, weight: .semibold))
                                .textCase(.uppercase)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.top, 10)
                        .padding(.bottom, 4)
                        ForEach(store.hidden) { item in
                            NotificationRow(item: item, now: store.now,
                                            open: { open(item.thread) },
                                            markRead: { Task { await store.markRead([item.thread]) } })
                                .opacity(0.6)
                            Divider().padding(.leading, 42)
                        }
                    }
                }
            }
            .frame(height: listHeight)
        }
    }

    private var listHeight: CGFloat {
        let rows = store.shown.count + (showHidden ? store.hidden.count + 1 : 0) + (store.error == nil ? 0 : 1)
        return min(CGFloat(max(rows, 1)) * 62, 480)
    }

    private func open(_ thread: NotificationThread) {
        store.open(thread)
        actions.closePopover()
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if !store.hidden.isEmpty {
                Button {
                    showHidden.toggle()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: showHidden ? "eye.slash" : "line.3.horizontal.decrease.circle")
                        Text(showHidden ? "Hide filtered" : "\(store.hidden.count) filtered")
                    }
                }
                .buttonStyle(.borderless)
                .help("Notifications your filters hide. They don't count toward the badge.")
            } else if store.isEnriching {
                ProgressView().controlSize(.mini)
                Text("Applying filters…")
            } else if let fetched = store.lastFetched {
                Text("Updated \(Fmt.ago(fetched, now: store.now))")
            }
            Spacer()
            Button("Open Forgejo") { actions.openWeb(); actions.closePopover() }
                .buttonStyle(.borderless)
            Button("Quit") { actions.quit() }
                .buttonStyle(.borderless)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
}

// MARK: - Row

struct NotificationRow: View {
    let item: DisplayItem
    let now: Date
    let open: () -> Void
    let markRead: () -> Void
    @State private var hovering = false

    private var thread: NotificationThread { item.thread }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 18)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(thread.repository.fullName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let number = thread.number {
                        Text(number).foregroundStyle(.tertiary)
                    }
                    if thread.pinned {
                        Image(systemName: "pin.fill").font(.system(size: 8))
                    }
                    Spacer(minLength: 4)
                    if let reason = item.hiddenReason {
                        Text(reason)
                            .lineLimit(1)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                    }
                    Text(Fmt.ago(thread.updatedAt, now: now, short: true))
                        .monospacedDigit()
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                Text(thread.subject.title)
                    .font(.system(size: 12.5, weight: thread.unread ? .medium : .regular))
                    .foregroundStyle(thread.unread ? .primary : .secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if hovering && thread.unread {
                Button(action: markRead) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Mark as read")
            } else if thread.unread {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 7, height: 7)
                    .frame(width: 22, height: 22)
            } else {
                Color.clear.frame(width: 22, height: 22)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(hovering ? Color.primary.opacity(0.06) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
        .help(thread.webURL?.absoluteString ?? "")
    }

    private var symbol: String {
        switch thread.subject.type {
        case .pull:
            switch thread.subject.state {
            case .merged: "arrow.triangle.merge"
            case .closed: "xmark.circle"
            default: "arrow.triangle.pull"
            }
        case .issue:
            thread.subject.state == .closed ? "checkmark.circle" : "smallcircle.filled.circle"
        case .commit: "point.topleft.down.to.point.bottomright.curvepath"
        case .repository: "tag"
        case .other: "bell"
        }
    }

    private var tint: Color {
        switch thread.subject.state {
        case .merged: .purple
        case .closed: thread.subject.type == .issue ? .purple : .red
        case .open: .green
        case nil: .secondary
        }
    }
}

// MARK: - Bits

struct ErrorLine: View {
    let error: ForgejoError

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("\(error.title). \(error.message)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

struct StatusMessage: View {
    let error: ForgejoError?
    let retry: () -> Void
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            if let error {
                Image(systemName: error.symbol)
                    .font(.system(size: 26))
                    .foregroundStyle(.secondary)
                Text(error.title)
                    .font(.system(size: 13, weight: .semibold))
                Text(error.message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Settings…", action: openSettings)
                    Button("Try Again", action: retry)
                }
                .controlSize(.small)
            } else {
                ProgressView().controlSize(.small)
                Text("Loading notifications…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }
}

struct IconButton: View {
    let systemName: String
    let help: String
    var busy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if busy {
                    ProgressView().controlSize(.small).scaleEffect(0.65)
                } else {
                    Image(systemName: systemName).font(.system(size: 12, weight: .medium))
                }
            }
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
        .disabled(busy)
    }
}

enum Fmt {
    static func ago(_ date: Date, now: Date, short: Bool = false) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return short ? "now" : "just now" }
        let minutes = Int(seconds / 60)
        let value: String
        if minutes < 60 { value = "\(minutes)m" }
        else if minutes < 60 * 24 { value = "\(minutes / 60)h" }
        else if minutes < 60 * 24 * 30 { value = "\(minutes / 1440)d" }
        else {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d"
            return formatter.string(from: date)
        }
        return short ? value : "\(value) ago"
    }
}
