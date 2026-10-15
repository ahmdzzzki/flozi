import AppKit
import SwiftUI
import FloziCore

@main
enum FloziApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NSPanel!
    private var status: NSStatusItem!
    let model = FloziModel()
    private var expanded = false
    private var observer: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Flozi"
        panel.setAccessibilityLabel("Flozi notch companion")
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.contentView = NSHostingView(rootView: NotchView(model: model, resize: { [weak self] value in
            self?.expanded = value
            self?.position()
        }))
        if model.mascot == nil { model.pinned = true; expanded = true }
        position()
        panel.orderFrontRegardless()
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Flozi")
        let menu = NSMenu()
        menu.addItem(withTitle: "Show Flozi", action: #selector(show), keyEquivalent: "")
        menu.addItem(withTitle: "Quit Flozi", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        status.menu = menu
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                         object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.position() }
        }
        model.start()
    }

    private func position() {
        guard let screen = NSScreen.screens.first else { return }
        let left = screen.auxiliaryTopLeftArea, right = screen.auxiliaryTopRightArea
        let camera = (left != nil && right != nil) ? max(0, right!.minX - left!.maxX) : 0
        model.cameraWidth = camera
        let width = expanded ? max(480, camera + 280) : max(320, camera + 250)
        let height: CGFloat = expanded ? 390 : max(36, screen.safeAreaInsets.top)
        panel.setFrame(NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height,
                              width: width, height: height), display: true)
    }
    @objc private func show() { expanded = true; model.pinned = true; position(); panel.orderFrontRegardless() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { show(); return true }
    @objc private func quit() { NSApp.terminate(nil) }
}

enum Mascot: String, CaseIterable, Identifiable {
    case robot, cat, ghost, capybara
    var id: String { rawValue }
    var label: String {
        switch self { case .robot: "Robot"; case .cat: "Cat"; case .ghost: "Ghost"; case .capybara: "Capy" }
    }
    var color: Color {
        switch self {
        case .robot: Color(red: 0.57, green: 0.95, blue: 0.76)
        case .cat: Color(red: 1, green: 0.80, blue: 0.65)
        case .ghost: Color(red: 0.80, green: 0.73, blue: 1)
        case .capybara: Color(red: 0.78, green: 0.55, blue: 0.34)
        }
    }
}

@MainActor
final class FloziModel: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var message = "Connecting to local Codex…"
    @Published var connected = false
    @Published var cameraWidth: CGFloat = 0
    @Published var pinned = false
    @Published var demo = false
    @Published var mascot: Mascot? {
        didSet { UserDefaults.standard.set(mascot?.rawValue, forKey: "mascot") }
    }
    @Published var sound = UserDefaults.standard.bool(forKey: "sound") {
        didSet { UserDefaults.standard.set(sound, forKey: "sound") }
    }
    @Published var volume = UserDefaults.standard.object(forKey: "volume") as? Double ?? 0.25 {
        didSet { UserDefaults.standard.set(volume, forKey: "volume") }
    }
    let reader = SessionReader()
    private var polling: Task<Void, Never>?
    private var initialized = false
    private var playingSound: NSSound?
    private var lastCue = Date.distantPast

    init() {
        mascot = UserDefaults.standard.string(forKey: "mascot").flatMap(Mascot.init(rawValue:))
    }
    var running: Int { sessions.filter { $0.activity.isRunning && Date().timeIntervalSince($0.updated) < 600 }.count }
    var visibleSessions: [Session] {
        if demo {
            var example = Session(id: "preview")
            example.project = "Avatar preview"
            example.activity = .working
            example.started = Date().addingTimeInterval(-42)
            example.updated = Date()
            return [example]
        }
        return Array(sessions.filter { Date().timeIntervalSince($0.updated) < 86400 }.prefix(3))
    }
    func start() {
        polling = Task { [weak self] in
            guard let self else { return }
            let base = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
            let root = base.appendingPathComponent("sessions")
            while !Task.isCancelled {
                do {
                    let next = try await reader.scan(root: root)
                    let previous = Dictionary(sessions.map { ($0.id, $0.activity) }, uniquingKeysWith: { _, new in new })
                    if initialized && next.contains(where: { $0.activity == .completed && previous[$0.id]?.isRunning == true }) {
                        cue()
                    }
                    sessions = next
                    connected = true
                    message = next.isEmpty ? "Connected · waiting for a Codex session" : "Local Codex · experimental adapter"
                    initialized = true
                } catch {
                    connected = false
                    sessions = []
                    message = "Cannot read Codex sessions · check local folder access"
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
    func cue(preview: Bool = false) {
        guard (sound || preview), preview || Date().timeIntervalSince(lastCue) > 2 else { return }
        let name: String
        switch mascot {
        case .cat: name = "Purr"
        case .ghost: name = "Blow"
        case .capybara: name = "Pop"
        default: name = "Tink"
        }
        playingSound?.stop()
        playingSound = NSSound(named: NSSound.Name(name))
        playingSound?.volume = Float(volume)
        playingSound?.play()
        lastCue = Date()
    }
}

struct NotchView: View {
    @ObservedObject var model: FloziModel
    let resize: (Bool) -> Void
    @State private var hovering = false
    @State private var collapse: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var expanded: Bool { hovering || model.pinned }
    private let mint = Color(red: 0.57, green: 0.95, blue: 0.76)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Group {
                    if let mascot = model.mascot {
                        AvatarView(mascot: mascot, active: model.running > 0 || model.demo)
                            .frame(width: 27, height: 27)
                    } else {
                        Image(systemName: "sparkles").foregroundStyle(mint)
                    }
                }
                Text("flozi").font(.system(size: 13, weight: .semibold, design: .rounded))
                Spacer(minLength: model.cameraWidth > 0 ? model.cameraWidth + 14 : 20)
                Circle().fill(model.connected ? mint : .orange).frame(width: 5, height: 5)
                Text(model.demo ? "Preview" : model.running > 0 ? "\(model.running) active" : "\(model.connected ? "Chilling" : "Offline")")
                    .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.75))
            }
            .padding(.horizontal, 18)
            .frame(height: max(36, NSScreen.screens.first?.safeAreaInsets.top ?? 36))
            .contentShape(Rectangle())
            .onTapGesture { model.pinned.toggle() }

            if expanded {
                VStack(alignment: .leading, spacing: 15) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.mascot == nil ? "Meet your little companion" : "A little company while AI works.")
                                .font(.system(size: 17, weight: .semibold, design: .rounded))
                            Text(model.demo ? "PREVIEW · sample activity" : model.message)
                                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                        }
                        Spacer()
                        Button { model.pinned.toggle() } label: {
                            Image(systemName: model.pinned ? "pin.fill" : "pin")
                        }.help("Keep Flozi expanded")
                    }
                    if model.mascot == nil {
                        Text("Choose an avatar below. You can change it anytime.")
                            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                            .frame(height: 66, alignment: .leading)
                    } else if model.visibleSessions.isEmpty {
                        HStack(spacing: 14) {
                            AvatarView(mascot: model.mascot!, active: false).frame(width: 50, height: 50)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("All quiet for now").font(.system(size: 13, weight: .medium))
                                Text("Start a task in Codex. I’ll keep an eye out.")
                                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                            }
                        }.frame(height: 66)
                    } else {
                        VStack(spacing: 7) {
                            ForEach(model.visibleSessions) { session in
                                HStack {
                                    Circle().fill(session.activity.isRunning ? mint : .white.opacity(0.4)).frame(width: 5, height: 5)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(session.project).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                        Text(Date().timeIntervalSince(session.updated) > 600 && session.activity.isRunning
                                             ? "Last seen working · no recent event" : session.activity.label)
                                            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                                    }
                                    Spacer()
                                    if session.activity.isRunning, let started = session.started {
                                        Text(started, style: .timer).monospacedDigit().font(.system(size: 11)).foregroundStyle(mint)
                                    } else {
                                        Image(systemName: session.activity == .completed ? "checkmark.circle" : "minus.circle")
                                            .foregroundStyle(.white.opacity(0.4))
                                    }
                                }
                            }
                        }.frame(minHeight: 66, alignment: .top)
                    }
                    HStack(spacing: 9) {
                        ForEach(Mascot.allCases) { mascot in
                            Button { model.mascot = mascot } label: {
                                VStack(spacing: 3) {
                                    AvatarView(mascot: mascot, active: false).frame(width: 35, height: 35)
                                    Text(mascot.label).font(.system(size: 10, weight: .medium, design: .rounded))
                                }
                                .frame(maxWidth: .infinity).padding(.vertical, 7)
                                .background(model.mascot == mascot ? mascot.color.opacity(0.15) : .white.opacity(0.035), in: RoundedRectangle(cornerRadius: 13))
                                .overlay(RoundedRectangle(cornerRadius: 13).stroke(model.mascot == mascot ? mascot.color.opacity(0.65) : .clear))
                            }.accessibilityLabel("Choose \(mascot.label) avatar")
                        }
                    }
                    HStack(spacing: 10) {
                        Button { model.sound.toggle() } label: {
                            Image(systemName: model.sound ? "speaker.wave.2" : "speaker.slash")
                        }.help(model.sound ? "Mute completion sounds" : "Enable completion sounds")
                        Slider(value: $model.volume, in: 0...0.7).frame(width: 65).accessibilityLabel("Sound volume")
                        Button("Listen") { model.cue(preview: true) }.font(.system(size: 10))
                        Spacer()
                        Button(model.demo ? "End preview" : "Preview") { model.demo.toggle() }.font(.system(size: 10))
                        Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.help("Quit Flozi")
                    }.foregroundStyle(.white.opacity(0.6))
                    Text("\(model.running) recent active · up to 3 shown · local sessions only")
                        .font(.system(size: 9)).foregroundStyle(.white.opacity(0.3))
                }
                .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 20)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background(Color(red: 0.035, green: 0.04, blue: 0.045))
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: expanded ? 26 : 16, bottomTrailingRadius: expanded ? 26 : 16))
        .overlay(alignment: .bottom) { if expanded { Capsule().fill(mint.opacity(0.3)).frame(width: 34, height: 3).padding(.bottom, 7) } }
        .frame(maxHeight: .infinity, alignment: .top)
        .onHover { inside in
            collapse?.cancel()
            if inside { hovering = true } else {
                collapse = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    if !Task.isCancelled { hovering = false }
                }
            }
        }
        .onChange(of: expanded) { _, value in resize(value) }
    }
}

/// Lightweight native vector mascots; final illustrated assets remain a user choice.
struct AvatarView: View {
    let mascot: Mascot
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: active && !reduceMotion ? 0.12 : 2, paused: !active || reduceMotion)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let w = size.width, h = size.height
                let lift = active && !reduceMotion ? sin(phase * 4) * h * 0.035 : 0
                func ellipse(_ rect: CGRect, _ color: Color) { context.fill(Path(ellipseIn: rect), with: .color(color)) }
                func round(_ rect: CGRect, _ radius: CGFloat, _ color: Color) {
                    context.fill(Path(roundedRect: rect, cornerRadius: radius), with: .color(color))
                }
                let color = mascot.color
                if mascot == .cat {
                    var ears = Path()
                    ears.move(to: CGPoint(x: w * 0.17, y: h * 0.4 + lift))
                    ears.addLine(to: CGPoint(x: w * 0.18, y: h * 0.06 + lift))
                    ears.addLine(to: CGPoint(x: w * 0.45, y: h * 0.28 + lift))
                    ears.closeSubpath()
                    ears.move(to: CGPoint(x: w * 0.58, y: h * 0.25 + lift))
                    ears.addLine(to: CGPoint(x: w * 0.83, y: h * 0.06 + lift))
                    ears.addLine(to: CGPoint(x: w * 0.85, y: h * 0.4 + lift))
                    ears.closeSubpath()
                    context.fill(ears, with: .color(color))
                }
                if mascot == .robot {
                    round(CGRect(x: w * 0.47, y: lift, width: w * 0.06, height: h * 0.24), w * 0.03, color)
                    ellipse(CGRect(x: w * 0.42, y: lift, width: w * 0.16, height: h * 0.16), color)
                }
                if mascot == .capybara {
                    ellipse(CGRect(x: w * 0.15, y: h * 0.12 + lift, width: w * 0.22, height: h * 0.25), color)
                    ellipse(CGRect(x: w * 0.65, y: h * 0.12 + lift, width: w * 0.22, height: h * 0.25), color)
                }
                round(CGRect(x: w * 0.08, y: h * 0.22 + lift, width: w * 0.84, height: h * 0.69), w * 0.30, color)
                if mascot == .robot {
                    round(CGRect(x: w * 0.21, y: h * 0.36 + lift, width: w * 0.58, height: h * 0.37), w * 0.12, Color(red: 0.94, green: 0.95, blue: 0.79))
                }
                if mascot == .ghost {
                    for x in [0.10, 0.36, 0.62] {
                        ellipse(CGRect(x: w * x, y: h * 0.73 + lift, width: w * 0.28, height: h * 0.22), color)
                    }
                }
                if mascot == .capybara {
                    ellipse(CGRect(x: w * 0.34, y: h * 0.48 + lift, width: w * 0.35, height: h * 0.34), Color(red: 0.50, green: 0.31, blue: 0.20))
                }
                let blink = Int(phase * 3) % 17 == 0
                for x in [0.34, 0.61] {
                    round(CGRect(x: w * x, y: h * 0.48 + lift, width: w * 0.07, height: h * (blink ? 0.025 : 0.10)), w * 0.04, .black.opacity(0.8))
                }
                for x in [0.20, 0.72] {
                    ellipse(CGRect(x: w * x, y: h * 0.61 + lift, width: w * 0.10, height: h * 0.055), .pink.opacity(0.45))
                }
                round(CGRect(x: w * 0.46, y: h * 0.64 + lift, width: w * 0.09, height: h * 0.035), w * 0.02, .black.opacity(0.65))
            }
        }.accessibilityLabel("\(mascot.label), \(active ? "working" : "resting")")
    }
}
