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
    private var pointerTimer: Timer?
    private var screenObserver: NSObjectProtocol?
    private var exitTime: Date?
    private let model = FloziModel()

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
        panel.contentView = NSHostingView(rootView: NotchView(model: model))
        position()
        panel.orderFrontRegardless()
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Flozi")
        let menu = NSMenu()
        menu.addItem(withTitle: "Show Flozi", action: #selector(show), keyEquivalent: "")
        menu.addItem(withTitle: "Quit Flozi", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        status.menu = menu
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.position() } }
        // Mouse location is read without event taps, Accessibility access, or screen capture.
        // The transparent hosting panel stays fixed, leaving room for a real SwiftUI spring.
        pointerTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackPointer() }
        }
        pointerTimer?.tolerance = 0.01
        model.start()
    }

    private func position() {
        guard let screen = NSScreen.screens.first else { return }
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            model.cameraWidth = max(0, right.minX - left.maxX)
        } else { model.cameraWidth = 0 }
        model.headerHeight = max(36, screen.safeAreaInsets.top)
        let width = model.openWidth + 28
        panel.setFrame(NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - model.panelHeight,
                              width: width, height: model.panelHeight), display: true)
        trackPointer()
    }

    private func trackPointer() {
        guard panel != nil else { return }
        let point = NSEvent.mouseLocation
        let width = model.expanded ? model.openWidth : model.closedWidth
        let height = model.expanded ? model.openHeight : model.headerHeight
        let visible = NSRect(x: panel.frame.midX - width / 2, y: panel.frame.maxY - height,
                             width: width, height: height)
        let overSurface = visible.contains(point)
        // Only the painted notch intercepts clicks. Transparent space remains click-through.
        panel.ignoresMouseEvents = !overSurface
        let nearNotch = visible.insetBy(dx: -5, dy: -5).contains(point)
        if nearNotch {
            exitTime = nil
            if !model.hovering { model.hovering = true }
        } else if model.hovering {
            if exitTime == nil { exitTime = Date() }
            if Date().timeIntervalSince(exitTime!) > 0.3 { model.hovering = false; exitTime = nil }
        }
        if model.expanded {
            let x = min(1, max(-1, (point.x - panel.frame.midX) / (model.openWidth / 2)))
            let y = min(1, max(-1, (point.y - (panel.frame.maxY - 130)) / 200))
            if abs(model.lookX - x) > 0.03 { model.lookX = x }
            if abs(model.lookY - y) > 0.03 { model.lookY = y }
        }
    }
    @objc private func show() { model.pinned = true; panel.orderFrontRegardless() }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { show(); return true }
    func applicationWillTerminate(_ notification: Notification) { pointerTimer?.invalidate() }
}

@MainActor
final class FloziModel: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var connected = false
    @Published var hasScanned = false
    @Published var now = Date()
    @Published var cameraWidth: CGFloat = 0
    @Published var headerHeight: CGFloat = 36
    @Published var pinned = false
    @Published var hovering = false
    @Published var lookX: Double = 0
    @Published var lookY: Double = 0
    @Published var previewMode: CompanionMode?
    @Published var sound = UserDefaults.standard.bool(forKey: "sound") {
        didSet { UserDefaults.standard.set(sound, forKey: "sound") }
    }
    @Published var volume = UserDefaults.standard.object(forKey: "volume") as? Double ?? 0.25 {
        didSet { UserDefaults.standard.set(volume, forKey: "volume") }
    }
    let launched = Date()
    let reader = SessionReader()
    private var polling: Task<Void, Never>?
    private var initialized = false
    private var playingSound: NSSound?
    private var lastCue = Date.distantPast

    var expanded: Bool { hovering || pinned }
    var closedWidth: CGFloat { max(330, cameraWidth + 250) }
    var openWidth: CGFloat { max(500, cameraWidth + 280) }
    var openHeight: CGFloat { headerHeight + 392 }
    var panelHeight: CGFloat { openHeight + 18 }
    var active: [Session] { sessions.filter { $0.turnActive && now.timeIntervalSince($0.updated) < 600 } }
    var liveMode: CompanionMode { CompanionMode.resolve(sessions: sessions, connected: connected, now: now, idleSince: launched) }
    var mode: CompanionMode { previewMode ?? liveMode }
    var visibleSessions: [Session] {
        Array(sessions.filter { now.timeIntervalSince($0.updated) < 86400 }.sorted {
            if $0.turnActive != $1.turnActive { return $0.turnActive }
            return $0.updated > $1.updated
        }.prefix(3))
    }
    var connectionLabel: String {
        if !hasScanned { return "Connecting to Codex…" }
        return connected ? "Local Codex" : "Local sessions unavailable"
    }
    func start() {
        polling = Task { [weak self] in
            guard let self else { return }
            let base = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
            let root = base.appendingPathComponent("sessions")
            while !Task.isCancelled {
                now = Date()
                let oldMode = liveMode
                do {
                    let next = try await reader.scan(root: root)
                    let previous = Dictionary(sessions.map { ($0.id, $0.turnActive) }, uniquingKeysWith: { _, new in new })
                    if initialized && next.contains(where: { $0.activity == .completed && previous[$0.id] == true && !$0.turnActive }) {
                        cue("complete")
                    }
                    sessions = next
                    connected = true
                    if initialized && liveMode != oldMode {
                        if liveMode == .error { cue("attention") }
                        else if liveMode == .waiting { cue("waiting") }
                        else if active.count > 0 && [.idle, .sleeping].contains(oldMode) { cue("start") }
                    }
                    initialized = true
                } catch { connected = false; sessions = [] }
                hasScanned = true
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }
    func cue(_ name: String = "complete", preview: Bool = false) {
        guard sound || preview, preview || Date().timeIntervalSince(lastCue) > 2 else { return }
        guard let url = Bundle.module.url(forResource: "flozi-\(name)", withExtension: "wav") else { return }
        playingSound?.stop()
        playingSound = NSSound(contentsOf: url, byReference: false)
        playingSound?.volume = Float(volume)
        playingSound?.play()
        lastCue = Date()
    }
}

extension CompanionMode {
    var tint: Color {
        switch self {
        case .success: Color(red: 0.55, green: 0.94, blue: 0.78)
        case .error, .interrupted: Color(red: 1, green: 0.66, blue: 0.57)
        case .waiting: Color(red: 1, green: 0.82, blue: 0.51)
        case .offline, .uncertain: Color(red: 0.65, green: 0.68, blue: 0.75)
        default: Color(red: 0.79, green: 0.72, blue: 1)
        }
    }
    var symbol: String {
        switch self {
        case .idle: "sparkles"; case .thinking: "ellipsis.bubble"; case .working: "gearshape.2"
        case .reading: "book"; case .searching: "magnifyingglass"; case .coding: "curlybraces"
        case .testing: "checkmark.shield"; case .waiting: "hourglass"; case .success: "checkmark.circle"
        case .error: "exclamationmark.circle"; case .interrupted: "pause.circle"; case .sleeping: "moon.zzz"
        case .offline: "wifi.slash"; case .uncertain: "questionmark.circle"
        }
    }
}

struct NotchView: View {
    @ObservedObject var model: FloziModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var expanded: Bool { model.expanded }
    private var mood: CompanionMode { model.mode }

    var body: some View {
        VStack(spacing: 0) {
            header
            if expanded {
                VStack(spacing: 16) {
                    hero
                    sessionList
                    previewBar
                    footer
                }
                .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 20)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -12)))
            }
        }
        .frame(width: expanded ? model.openWidth : model.closedWidth,
               height: expanded ? model.openHeight : model.headerHeight, alignment: .top)
        .background {
            ZStack {
                Color(red: 0.025, green: 0.027, blue: 0.038)
                if expanded {
                    RadialGradient(colors: [mood.tint.opacity(0.12), .clear], center: .init(x: 0.18, y: 0.25), startRadius: 5, endRadius: 270)
                }
            }
        }
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: expanded ? 30 : 17, bottomTrailingRadius: expanded ? 30 : 17))
        .overlay(alignment: .bottom) {
            if expanded { Capsule().fill(mood.tint.opacity(0.35)).frame(width: 30, height: 3).padding(.bottom, 7) }
        }
        .overlay {
            UnevenRoundedRectangle(bottomLeadingRadius: expanded ? 30 : 17, bottomTrailingRadius: expanded ? 30 : 17)
                .strokeBorder(.white.opacity(expanded ? 0.07 : 0.025), lineWidth: 0.7)
        }
        .animation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.42, dampingFraction: 0.82), value: expanded)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: mood)
        .foregroundStyle(.white)
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        Button { model.pinned.toggle() } label: {
        HStack(spacing: 8) {
            FloziAvatar(mode: mood, lookX: 0, lookY: 0).frame(width: 30, height: 30)
            Text("flozi").font(.system(size: 13, weight: .semibold, design: .rounded))
            Spacer(minLength: model.cameraWidth > 0 ? model.cameraWidth + 12 : 10)
            Circle().fill(mood.tint).frame(width: 5, height: 5)
            Text(model.previewMode != nil ? "Preview" : !model.hasScanned ? "Connecting" : mood.label)
                .font(.system(size: 10, weight: .medium, design: .rounded)).lineLimit(1)
                .foregroundStyle(mood.tint)
            if model.active.count > 1 && model.previewMode == nil {
                Text("\(model.active.count)").font(.system(size: 9, weight: .bold)).padding(4)
                    .background(.white.opacity(0.08), in: Circle())
            }
        }
        .padding(.horizontal, 14).frame(height: model.headerHeight)
        .contentShape(Rectangle())
        }
        .accessibilityLabel(model.expanded ? "Toggle Flozi pin" : "Open Flozi")
        .help("Hover to open Flozi. Click to pin.")
    }

    private var hero: some View {
        HStack(spacing: 16) {
            FloziAvatar(mode: mood, lookX: model.lookX, lookY: model.lookY)
                .frame(width: 114, height: 114)
                .background { Circle().fill(mood.tint.opacity(0.06)).blur(radius: 15) }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(model.previewMode == nil ? "YOUR LITTLE COMPANION" : "AVATAR PREVIEW")
                        .font(.system(size: 8, weight: .semibold)).tracking(1.6).foregroundStyle(.white.opacity(0.35))
                    Spacer(minLength: 0)
                    Button { model.pinned.toggle() } label: {
                        Image(systemName: model.pinned ? "pin.fill" : "pin").font(.system(size: 11))
                            .foregroundStyle(model.pinned ? mood.tint : .white.opacity(0.4))
                    }.accessibilityLabel(model.pinned ? "Unpin Flozi" : "Pin Flozi")
                }
                Text(!model.hasScanned && model.previewMode == nil ? "Waking up…" : mood.label)
                    .font(.system(size: 25, weight: .semibold, design: .rounded)).foregroundStyle(mood.tint)
                Text(mood.caption).font(.system(size: 11)).lineSpacing(3).foregroundStyle(.white.opacity(0.56))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.frame(height: 116)
    }

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                HStack(spacing: 5) {
                    Circle().fill(model.connected ? Color.mint : .orange).frame(width: 4, height: 4)
                    Text(model.connectionLabel)
                }
                Spacer()
                Text("\(model.active.count) active · \(model.visibleSessions.count) shown")
            }.font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.4))
            if model.visibleSessions.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.connected ? "Nothing running. Make yourself comfy." : "Waiting for local session access.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                    Text(model.connected ? "Start a task in Codex. Flozi will keep you company." : "Check that Codex has created its local sessions folder.")
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
                }.frame(maxWidth: .infinity, minHeight: 83, alignment: .leading)
            } else {
                VStack(spacing: 6) {
                    ForEach(model.visibleSessions) { session in
                        HStack(spacing: 9) {
                            Image(systemName: session.activity == .completed ? "checkmark.circle" : "circle.dotted")
                                .font(.system(size: 11)).foregroundStyle(session.turnActive ? mood.tint : .white.opacity(0.35))
                            Text(session.project).font(.system(size: 11, weight: .medium)).lineLimit(1)
                            Spacer(minLength: 6)
                            Text(session.turnActive && model.now.timeIntervalSince(session.updated) >= 600 ? "No fresh event" : session.activity.label)
                                .font(.system(size: 9)).foregroundStyle(.white.opacity(0.45))
                            if session.turnActive, let started = session.started {
                                Text(started, style: .timer).monospacedDigit().font(.system(size: 9)).foregroundStyle(.white.opacity(0.45))
                                    .frame(width: 41, alignment: .trailing)
                            }
                        }.frame(height: 23)
                    }
                }.frame(height: 83, alignment: .top)
            }
        }
        .padding(13).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
        .frame(height: 128)
        .opacity(model.previewMode == nil ? 1 : 0.5)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Live Codex sessions")
    }

    private var previewBar: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(CompanionMode.allCases) { mode in
                    Button { model.previewMode = mode } label: { Label(mode.label, systemImage: mode.symbol) }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "face.smiling")
                    Text(model.previewMode == nil ? "Try a mood" : "Preview: \(mood.label)")
                    Image(systemName: "chevron.down").font(.system(size: 8))
                }.font(.system(size: 10, weight: .medium)).padding(.horizontal, 11).padding(.vertical, 8)
                    .background(mood.tint.opacity(0.10), in: Capsule()).foregroundStyle(mood.tint)
            }.menuStyle(.borderlessButton).fixedSize()
            Spacer()
            if model.previewMode != nil {
                Button("Back to live") { model.previewMode = nil }
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(Color.mint)
            } else {
                Text("Last observed activity").font(.system(size: 9)).foregroundStyle(.white.opacity(0.3))
            }
        }.frame(height: 30)
    }

    private var footer: some View {
        HStack(spacing: 11) {
            Button { model.sound.toggle() } label: {
                Image(systemName: model.sound ? "speaker.wave.2" : "speaker.slash").frame(width: 15)
            }.accessibilityLabel(model.sound ? "Mute Flozi sounds" : "Enable Flozi sounds")
            Slider(value: $model.volume, in: 0...0.7).tint(mood.tint).frame(width: 65).accessibilityLabel("Sound volume")
            Menu {
                Button("Start · little hello") { model.cue("start", preview: true) }
                Button("Done · tiny celebration") { model.cue("complete", preview: true) }
                Button("Waiting · gentle nudge") { model.cue("waiting", preview: true) }
                Button("Attention · soft wobble") { model.cue("attention", preview: true) }
            } label: { Text("Sounds").font(.system(size: 10)) }.menuStyle(.borderlessButton).fixedSize()
            Spacer()
            Text("flozi ♡").font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.25))
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.accessibilityLabel("Quit Flozi")
        }.font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).frame(height: 23)
    }
}

@MainActor
private enum FloziSprites {
    static let frames: [NSImage] = {
        guard let url = Bundle.module.url(forResource: "flozi-atlas", withExtension: "png"),
              let source = NSImage(contentsOf: url),
              let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
        return (0..<16).compactMap { index in
            let cell = CGRect(x: Double(index % 4) * Double(cg.width) / 4,
                              y: Double(index / 4) * Double(cg.height) / 4,
                              width: Double(cg.width) / 4, height: Double(cg.height) / 4).integral
            return cg.cropping(to: cell).map { NSImage(cgImage: $0, size: NSSize(width: 256, height: 256)) }
        }
    }()
}

struct FloziAvatar: View {
    let mode: CompanionMode
    let lookX: Double
    let lookY: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduceMotion || !mode.animated)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let frame = sprite(at: t)
            Group {
                if FloziSprites.frames.indices.contains(frame) {
                    Image(nsImage: FloziSprites.frames[frame]).resizable().interpolation(.high).scaledToFit()
                } else { Image(systemName: "sparkles").resizable().scaledToFit().foregroundStyle(mode.tint) }
            }
            .scaleEffect(reduceMotion ? 1 : 1 + sin(t * (mode == .thinking ? 2.2 : 1.7)) * 0.025)
            .rotationEffect(.degrees(reduceMotion ? 0 : tilt(t)))
            .rotation3DEffect(.degrees(reduceMotion ? 0 : lookX * 9), axis: (x: 0, y: 1, z: 0), perspective: 0.3)
            .rotation3DEffect(.degrees(reduceMotion ? 0 : -lookY * 5), axis: (x: 1, y: 0, z: 0), perspective: 0.3)
            .offset(y: reduceMotion ? 0 : sin(t * speed) * 3)
            .shadow(color: mode.tint.opacity(0.13), radius: 8, y: 3)
        }
        .accessibilityLabel("Flozi, \(mode.label)")
    }
    private var speed: Double { [.working, .coding, .testing].contains(mode) ? 4.5 : 2 }
    private func sprite(at time: Double) -> Int {
        guard !reduceMotion else { return mode.spriteIndex }
        if mode == .idle && Int(time * 4) % 21 == 0 { return 15 }
        if mode == .thinking && Int(time * 1.5) % 2 == 0 { return 14 }
        return mode.spriteIndex
    }
    private func tilt(_ time: Double) -> Double {
        switch mode {
        case .success: sin(time * 6) * 5
        case .error, .interrupted: sin(time * 5) * 2
        case .searching: sin(time * 2) * 6
        case .waiting: sin(time * 1.4) * 3
        case .sleeping, .offline, .uncertain: 0
        default: sin(time * 1.8) * 1.8
        }
    }
}
