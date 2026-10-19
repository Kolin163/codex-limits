import Cocoa

struct Quota: Decodable {
    struct Window: Decodable {
        let usedPercent: Double
        let windowDurationMins: Int?
        let resetsAt: Double?
        var remaining: Int { Int(max(0, min(100, 100 - usedPercent)).rounded(.down)) }
        var name: String {
            guard let m = windowDurationMins else { return "Лимит" }
            if m == 10080 { return "Неделя" }
            if m % 1440 == 0 { return "\(m / 1440) дн." }
            if m % 60 == 0 { return "\(m / 60) ч." }
            return "\(m) мин."
        }
    }
    let limitName: String?
    let primary: Window?
    let secondary: Window?
    var windows: [Window] { [primary, secondary].compactMap { $0 } }
}
struct Snapshot: Decodable {
    let rateLimits: Quota?
    let rateLimitsByLimitId: [String: Quota]?
    var quotas: [(String, Quota)] {
        if let all = rateLimitsByLimitId, !all.isEmpty {
            return all.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        }
        return rateLimits.map { [("codex", $0)] } ?? []
    }
    var remaining: Int? { quotas.flatMap { $0.1.windows }.map { $0.remaining }.min() }
}
enum FetchError: Error { case unavailable, failed }
func fetch() throws -> Snapshot {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let apps = ["/Applications/ChatGPT.app", "/Applications/Codex.app", home + "/Applications/ChatGPT.app", home + "/Applications/Codex.app"]
    let bundledPaths = apps.flatMap { app in
        [app + "/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
         app + "/Contents/Resources/codex", app + "/Contents/Resources/codex-cli/bin/codex"]
    }
    let fallbackPaths = [home + "/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
    let paths = bundledPaths + (CommandLine.arguments.contains("--desktop-check") ? [] : fallbackPaths)
    guard let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw FetchError.unavailable }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = ["app-server", "--stdio"]
    process.currentDirectoryURL = FileManager.default.temporaryDirectory
    let input = Pipe(), output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    defer {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        let cleanupDeadline = Date().addingTimeInterval(1)
        while process.isRunning && Date() < cleanupDeadline { usleep(10_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        try? output.fileHandleForReading.close()
    }
    let deadline = ProcessInfo.processInfo.systemUptime + 25
    func send(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
    }
    try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "codex_limits_menu", "title": "Codex Limits", "version": "1.0.0"]]])
    var buffer = Data()
    while true {
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw FetchError.failed }
        var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
        let ready = poll(&descriptor, 1, 250)
        if ready == 0 { continue }
        if ready < 0 { if errno == EINTR { continue }; throw FetchError.failed }
        var bytes = [UInt8](repeating: 0, count: 65536)
        let count = read(descriptor.fd, &bytes, bytes.count)
        guard count > 0 else { throw FetchError.failed }
        buffer.append(contentsOf: bytes.prefix(count))
        guard buffer.count <= 2_097_152 else { throw FetchError.failed }
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let id = object["id"] as? Int else { continue }
            if object["error"] != nil { throw FetchError.failed }
            if id == 1 {
                try send(["method": "initialized", "params": [:]])
                try send(["id": 2, "method": "account/rateLimits/read"])
            } else if id == 2, let result = object["result"] {
                return try JSONDecoder().decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: result))
            }
        }
    }
}

enum QuotaLevel {
    case healthy, medium, low
    init(_ percent: Int) { self = percent > 60 ? .healthy : (percent >= 25 ? .medium : .low) }
    var color: NSColor {
        switch self {
        case .healthy: return NSColor(calibratedRed: 0.05, green: 0.78, blue: 0.72, alpha: 1)
        case .medium: return NSColor(calibratedRed: 0.96, green: 0.69, blue: 0.08, alpha: 1)
        case .low: return NSColor(calibratedRed: 0.95, green: 0.25, blue: 0.27, alpha: 1)
        }
    }
}
func statusRing(_ percent: Int?) -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
        let track = NSBezierPath(ovalIn: NSRect(x: 3, y: 3, width: 12, height: 12))
        track.lineWidth = 2.5
        NSColor.secondaryLabelColor.withAlphaComponent(0.35).setStroke(); track.stroke()
        if let percent = percent, percent > 0 {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: 9, y: 9), radius: 6, startAngle: 90, endAngle: 90 + 360 * Double(percent) / 100, clockwise: false)
            arc.lineWidth = 2.5; arc.lineCapStyle = .round
            QuotaLevel(percent).color.setStroke(); arc.stroke()
        }
        return true
    }
    image.isTemplate = false
    return image
}
final class QuotaBar: NSView {
    let percent: Int
    init(percent: Int) {
        self.percent = percent
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 23))
        setAccessibilityElement(true)
        setAccessibilityLabel("Осталось \(percent)% лимита")
    }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        let color = QuotaLevel(percent).color
        for segment in 0..<10 {
            let rect = NSRect(x: 20 + CGFloat(segment) * 21, y: 6, width: 17, height: 11)
            let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
            color.withAlphaComponent(0.18).setFill(); path.fill()
            let fraction = max(0, min(1, CGFloat(percent) / 10 - CGFloat(segment)))
            if fraction > 0 {
                NSGraphicsContext.saveGraphicsState()
                NSRect(x: rect.minX, y: rect.minY, width: rect.width * fraction, height: rect.height).clip()
                color.setFill(); path.fill()
                NSGraphicsContext.restoreGraphicsState()
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var status: NSStatusItem!
    let menu = NSMenu()
    var snapshot: Snapshot?
    var updated: Date?
    var error: String?
    var busy = false
    var timer: Timer?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        status.button?.title = " …"
        status.button?.image = statusRing(nil)
        status.button?.imagePosition = .imageLeading
        menu.delegate = self
        status.menu = menu
        NotificationCenter.default.addObserver(self, selector: #selector(systemTimeChanged), name: NSNotification.Name.NSSystemTimeZoneDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(systemTimeChanged), name: NSNotification.Name.NSSystemClockDidChange, object: nil)
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 180, repeats: true) { [weak self] _ in self?.refresh() }
        timer?.tolerance = 15
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wake), name: NSWorkspace.didWakeNotification, object: nil)
    }
    @objc func wake() { refresh() }
    @objc func systemTimeChanged() {
        NSTimeZone.resetSystemTimeZone()
        rebuild()
    }
    func menuWillOpen(_ menu: NSMenu) { rebuild(); if Date().timeIntervalSince(updated ?? .distantPast) > 60 { refresh() } }
    func label(_ title: String) { let item = NSMenuItem(title: title, action: nil, keyEquivalent: ""); item.isEnabled = false; menu.addItem(item) }
    func rebuild() {
        menu.removeAllItems()
        label("Codex · остаток лимитов")
        menu.addItem(.separator())
        if let snapshot = snapshot {
            for (id, quota) in snapshot.quotas {
                if snapshot.quotas.count > 1 { label(quota.limitName ?? id) }
                for window in quota.windows {
                    label("\(window.name): осталось \(window.remaining)%")
                    let bar = NSMenuItem()
                    bar.view = QuotaBar(percent: window.remaining)
                    menu.addItem(bar)
                    if let reset = window.resetsAt {
                        let date = Date(timeIntervalSince1970: reset)
                        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "ru_RU"); formatter.timeZone = .autoupdatingCurrent; formatter.dateFormat = "d MMM, HH:mm (zzz)"
                        label("Сброс: " + formatter.string(from: date))
                        let seconds = max(0, Int(date.timeIntervalSinceNow))
                        label(seconds == 0 ? "Ожидаем обновления лимита" : "Через \(seconds / 86400) дн. \((seconds % 86400) / 3600) ч. \((seconds % 3600) / 60) мин.")
                    } else { label("Время сброса недоступно") }
                }
            }
            if snapshot.remaining == nil { label("Источник не вернул окна лимитов") }
        }
        if let error = error {
            label(error)
            let open = NSMenuItem(title: "Открыть Codex для входа", action: #selector(openCodex), keyEquivalent: "")
            open.target = self; menu.addItem(open)
        }
        menu.addItem(.separator())
        let age = updated.map { " · \(max(0, Int(Date().timeIntervalSince($0) / 60))) мин. назад" } ?? ""
        let refreshItem = NSMenuItem(title: busy ? "Обновление…" : "Обновить" + age, action: #selector(refresh), keyEquivalent: "r")
        refreshItem.target = self; refreshItem.isEnabled = !busy; menu.addItem(refreshItem)
        let quit = NSMenuItem(title: "Завершить Codex Limits", action: #selector(quitApp), keyEquivalent: "q"); quit.target = self; menu.addItem(quit)
    }
    @objc func openCodex() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = ["/Applications/Codex.app", "/Applications/ChatGPT.app", home + "/Applications/Codex.app", home + "/Applications/ChatGPT.app"]
        if let path = paths.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }
    @objc func quitApp() { NSApp.terminate(nil) }
    @objc func refresh() {
        guard !busy else { return }; busy = true
        rebuild()
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try fetch() }
            DispatchQueue.main.async {
                self.busy = false
                switch result {
                case .success(let data):
                    self.snapshot = data; self.updated = Date(); self.error = nil
                    self.status.button?.title = data.remaining.map { " \($0)%" } ?? " —"
                    self.status.button?.image = statusRing(data.remaining)
                    self.status.button?.toolTip = "Codex: осталось \(data.remaining.map(String.init) ?? "—")%. Нажмите для подробностей."
                case .failure(let problem):
                    self.error = (problem as? FetchError) == .unavailable ? "Установите Codex Desktop" : "Нет связи. Проверьте вход в Codex."
                    self.status.button?.title = " !"
                    self.status.button?.image = statusRing(nil)
                    self.status.button?.toolTip = "\(self.error!) Последние данные доступны в меню."
                }
                self.rebuild()
            }
        }
    }
}
if CommandLine.arguments.contains("--self-test") {
    assert(QuotaLevel(100) == .healthy && QuotaLevel(61) == .healthy)
    assert(QuotaLevel(60) == .medium && QuotaLevel(50) == .medium && QuotaLevel(25) == .medium)
    assert(QuotaLevel(24) == .low && QuotaLevel(0) == .low)
    print("Color thresholds OK: 61–100 teal, 25–60 yellow, 0–24 red")
} else if CommandLine.arguments.contains("--check") || CommandLine.arguments.contains("--check-repeat") || CommandLine.arguments.contains("--desktop-check") {
    do {
        for iteration in 1...(CommandLine.arguments.contains("--check-repeat") ? 5 : 1) {
            try autoreleasepool {
                let snapshot = try fetch()
                print("Check \(iteration) OK; quota groups: \(snapshot.quotas.count); remaining: \(snapshot.remaining.map(String.init) ?? "unavailable")%")
            }
        }
    } catch { print("Connection failed (no credentials or server unavailable)"); exit(1) }
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
