import AppKit

@MainActor
enum CLI {
    /// Fetches once with the app's settings and prints what the menu bar would show.
    static func printNotifications() -> Int32 {
        let store = NotificationStore()
        var finished = false
        Task {
            await store.refresh(userInitiated: true)
            finished = true
        }
        while !finished { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

        if let error = store.error {
            FileHandle.standardError.write(Data("\(error.title): \(error.message)\n".utf8))
            if store.lastFetched == nil { return 1 }
        }
        let color = isatty(STDOUT_FILENO) != 0
        func dim(_ text: String) -> String { color ? "\u{1B}[2m\(text)\u{1B}[0m" : text }
        func bold(_ text: String) -> String { color ? "\u{1B}[1m\(text)\u{1B}[0m" : text }

        print(bold("Forgejo notifications") + dim("  ·  \(store.credentialSource ?? "")  ·  @\(store.user?.login ?? "?")"))
        print("\(store.badgeCount) unread shown, \(store.hidden.count) hidden by filters\n")
        for item in store.shown {
            let thread = item.thread
            let head = [thread.repository.fullName, thread.number].compactMap { $0 }.joined(separator: " ")
            print("\(thread.unread ? "●" : " ") \(dim(head))  \(thread.subject.title)")
            if let url = thread.webURL { print("    \(dim(url.absoluteString))") }
        }
        if !store.hidden.isEmpty {
            let reasons = Dictionary(grouping: store.hidden.compactMap(\.hiddenReason), by: { $0 })
                .mapValues(\.count).sorted { $0.value > $1.value }
            print(dim("\nHidden: " + reasons.map { "\($0.key) ×\($0.value)" }.joined(separator: ", ")))
        }
        return 0
    }

    static func renderPreviews(to directory: String) {
        let dir = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = NSAppearance(named: appearanceName)!
            var models: [MenuBarModel] = []
            for color in IconColor.allCases {
                for badge in BadgeStyle.allCases {
                    models.append(MenuBarModel(state: .ok, count: 12, color: color, badge: badge))
                }
                models.append(MenuBarModel(state: .ok, count: 0, color: color, badge: .badge))
                models.append(MenuBarModel(state: .error, count: 0, color: color, badge: .badge))
            }
            let scale: CGFloat = 4
            let gap: CGFloat = 14
            let width = models.reduce(gap) { $0 + MenuBarRenderer.width(for: $1) + gap }
            let height: CGFloat = 22 * 2
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let context = NSGraphicsContext(bitmapImageRep: rep)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            let ctx = context.cgContext
            ctx.scaleBy(x: scale, y: scale)
            ctx.setFillColor(name == "dark" ? CGColor(gray: 0.16, alpha: 1) : CGColor(gray: 0.93, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            var x = gap
            for model in models {
                let w = MenuBarRenderer.width(for: model)
                ctx.saveGState()
                ctx.translateBy(x: x, y: 11)
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                MenuBarRenderer.draw(model, in: ctx, bounds: CGRect(x: 0, y: 0, width: w, height: 22), appearance: appearance)
                ctx.endTransparencyLayer()
                ctx.restoreGState()
                x += w + gap
            }
            context.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: dir.appendingPathComponent("menubar-\(name).png"))
            }
        }
        let icon = AppIcon.bitmap(side: 512) { ctx, side in AppIcon.draw(ctx, side: side) }
        if let data = icon.representation(using: .png, properties: [:]) {
            try? data.write(to: dir.appendingPathComponent("icon.png"))
        }
    }
}
