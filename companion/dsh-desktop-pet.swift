// dsh-desktop-pet 桌宠伴侣（macOS）— DeepSeek Harness 桌面宠物
//
// 通用兼容设计：
//  - 自动发现 DSH 实例（--base 优先 → DSH_WEB_PORT 环境变量 → 常见端口 62942/3080）
//  - 回到任务窗口的应用可配置（设置面板，默认 DSH Desktop；浏览器自动兜底）
//  - 中英双语，跟随系统语言（--lang zh|en|auto 覆盖）
//  - 只依赖 macOS 基础 API（10.15+），swiftc 即可编译
//
// 功能：
//  - 无边框、透明、置顶悬浮窗，用插件 sprite sheet 渲染宠物动画
//  - 轮询 {base}/dsh-desktop-pet/state 与 /sessions，显示当前任务状态
//  - presence 心跳：在场期间网页端宠物自动隐藏
//  - 单击宠物 → 回到任务窗口；双击 → 喂食；拖拽移动（系统级拖动，无卡顿无拖影）
//  - 右键 → 设置面板（大小/透明度/入睡时间/回窗口应用/开机自启动/退出）
//
// 用法：dsh-desktop-pet [--base http://127.0.0.1:62942] [--size 160] [--lang auto]
// 编译：swiftc -O dsh-desktop-pet.swift -o dsh-desktop-pet

import AppKit
import Darwin
import Foundation

// MARK: - 常量

let ROUTE_PREFIX = "/dsh-desktop-pet"
let PRESENCE_INTERVAL: TimeInterval = 15
let STATE_POLL_INTERVAL: TimeInterval = 2.0
let SESSIONS_POLL_INTERVAL: TimeInterval = 3.0
let BUBBLE_MS: TimeInterval = 4.0

let UD_SIZE = "dsh-desktop-pet:size"
let UD_OPACITY = "dsh-desktop-pet:opacity"
let UD_SLEEP_MS = "dsh-desktop-pet:sleepMs"
let UD_POS = "dsh-desktop-pet:pos"
let UD_FOCUS_APP = "dsh-desktop-pet:focusApp"

// MARK: - 国际化（中英双语，跟随系统）

var langMode = "auto" // auto | zh | en

func l(_ zh: String, _ en: String) -> String {
    switch langMode {
    case "zh": return zh
    case "en": return en
    default:
        let pref = Locale.preferredLanguages.first?.lowercased() ?? "zh"
        return pref.hasPrefix("zh") ? zh : en
    }
}

// MARK: - 命令行参数

func parseArgs() -> (base: String?, size: CGFloat, lang: String) {
    var base: String?
    var size: CGFloat = 160
    var lang = "auto"
    let args = CommandLine.arguments
    var i = 1
    while i < args.count {
        switch args[i] {
        case "--base":
            if i + 1 < args.count { base = args[i + 1]; i += 1 }
        case "--size":
            if i + 1 < args.count, let v = Double(args[i + 1]) { size = CGFloat(v); i += 1 }
        case "--lang":
            if i + 1 < args.count { lang = args[i + 1]; i += 1 }
        default: break
        }
        i += 1
    }
    if let b = base, b.hasSuffix("/") { base = String(b.dropLast()) }
    if !["zh", "en", "auto"].contains(lang) { lang = "auto" }
    return (base, size, lang)
}

// MARK: - 单实例锁

func acquireSingleInstanceLock() -> Bool {
    let lockPath = "/tmp/dsh-desktop-pet.lock"
    let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
    if fd < 0 { return true }
    if flock(fd, LOCK_EX | LOCK_NB) != 0 { return false }
    return true
}

// MARK: - 轻量 HTTP

func httpGet(_ url: String, _ completion: @escaping (Data?) -> Void) {
    guard let u = URL(string: url) else { completion(nil); return }
    var req = URLRequest(url: u)
    req.timeoutInterval = 8
    URLSession.shared.dataTask(with: req) { data, _, _ in
        DispatchQueue.main.async { completion(data) }
    }.resume()
}

func httpPost(_ url: String, _ body: [String: Any], _ completion: ((Data?) -> Void)? = nil) {
    guard let u = URL(string: url) else { completion?(nil); return }
    var req = URLRequest(url: u)
    req.httpMethod = "POST"
    req.timeoutInterval = 8
    req.setValue("application/json", forHTTPHeaderField: "content-type")
    req.httpBody = try? JSONSerialization.data(withJSONObject: body)
    URLSession.shared.dataTask(with: req) { data, _, _ in
        DispatchQueue.main.async { completion?(data) }
    }.resume()
}

// MARK: - 实例发现（同步探测，超时兜底）

func probeInstance(_ base: String) -> Bool {
    guard let url = URL(string: base + ROUTE_PREFIX + "/state") else { return false }
    let sem = DispatchSemaphore(value: 0)
    var ok = false
    var req = URLRequest(url: url)
    req.timeoutInterval = 2
    URLSession.shared.dataTask(with: req) { data, _, _ in
        if let data = data,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           json["apiVersion"] != nil {
            ok = true
        }
        sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + 2.5)
    return ok
}

func resolveBase(explicit: String?) -> String {
    var candidates: [String] = []
    if let b = explicit, !b.isEmpty { candidates.append(b) }
    if let port = ProcessInfo.processInfo.environment["DSH_WEB_PORT"], !port.isEmpty {
        candidates.append("http://127.0.0.1:\(port)")
    }
    candidates.append(contentsOf: ["http://127.0.0.1:62942", "http://127.0.0.1:3080"])
    for c in candidates where probeInstance(c) {
        return c
    }
    return explicit ?? "http://127.0.0.1:62942"
}

// MARK: - 精灵管理

struct StateSpec {
    let sheet: String
    let frames: Int
    let fps: Double
    let playback: String
}

final class SpriteManager {
    private(set) var frames: [String: [CGImage]] = [:]
    private(set) var specs: [String: StateSpec] = [:]
    var onUpdate: (() -> Void)?
    private let base: String

    init(base: String) { self.base = base }

    var loaded: Bool { !frames.isEmpty }

    func load() {
        httpGet("\(base)\(ROUTE_PREFIX)/assets/manifest.json") { [weak self] data in
            guard let self = self, let data = data else { return }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            guard let characters = json["characters"] as? [String: Any],
                  let pet = characters["whale-girl"] as? [String: Any],
                  let states = pet["states"] as? [String: Any] else { return }
            var specs: [String: StateSpec] = [:]
            for (name, raw) in states {
                guard let s = raw as? [String: Any],
                      let sheet = s["sheet"] as? String,
                      let frames = s["frames"] as? Int,
                      let fps = s["fps"] as? Double else { continue }
                let playback = (s["playback"] as? String) ?? "loop"
                specs[name] = StateSpec(sheet: sheet, frames: frames, fps: fps, playback: playback)
            }
            self.specs = specs
            let group = DispatchGroup()
            var result: [String: [CGImage]] = [:]
            let lock = NSLock()
            for (name, spec) in specs {
                group.enter()
                httpGet("\(self.base)\(ROUTE_PREFIX)/assets/characters/whale-girl/\(spec.sheet)") { data in
                    defer { group.leave() }
                    guard let data = data, let img = NSImage(data: data),
                          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
                    let fw = cg.width / max(1, spec.frames)
                    var list: [CGImage] = []
                    for f in 0..<spec.frames {
                        if let cropped = cg.cropping(to: CGRect(x: f * fw, y: 0, width: fw, height: cg.height)) {
                            list.append(cropped)
                        }
                    }
                    if !list.isEmpty { lock.lock(); result[name] = list; lock.unlock() }
                }
            }
            group.notify(queue: .main) {
                self.frames = result
                self.onUpdate?()
            }
        }
    }

    func frame(for state: String, elapsed: TimeInterval) -> CGImage? {
        guard let list = frames[state], !list.isEmpty else { return nil }
        guard let spec = specs[state] else { return list[0] }
        let n = list.count
        guard n > 1 else { return list[0] }
        let t = elapsed * spec.fps
        let idx: Int
        switch spec.playback {
        case "pingpong":
            let period = max(1, n * 2 - 2)
            let p = Int(t.truncatingRemainder(dividingBy: Double(period)))
            idx = p < n ? p : period - p
        case "once":
            idx = min(n - 1, Int(t))
        default:
            idx = Int(t) % n
        }
        return list[max(0, min(n - 1, idx))]
    }
}

// MARK: - 宠物视图

final class PetView: NSView {
    var petSize: CGFloat
    let sprites: SpriteManager

    var state = "idle"
    var flip: CGFloat = 1
    var stateSince = Date()
    var statusText = "☕ Idle"
    var bubbleText: String?
    var bubbleUntil = Date.distantPast
    var dragging = false

    private var windowStartOrigin: NSPoint?
    private var snapshotImage: NSImage?
    private var pressStartOrigin: NSPoint?
    private var pressMaxDist: CGFloat = 0
    private var pressFinalized = false
    private var activeMonitor: Any?

    let pillHeight: CGFloat = 26
    let topSpace: CGFloat = 40

    init(petSize: CGFloat, sprites: SpriteManager) {
        self.petSize = petSize
        self.sprites = sprites
        super.init(frame: NSRect(x: 0, y: 0, width: petSize + 24, height: 40 + petSize + 26 + 16))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func applySize(_ size: CGFloat) {
        petSize = size
        let w = size + 24
        let h = topSpace + size + pillHeight + 16
        setFrameSize(NSSize(width: w, height: h))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if let snap = snapshotImage {
            snap.draw(in: bounds)
            return
        }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        if let text = bubbleText, Date() < bubbleUntil {
            drawBubble(text, in: ctx)
        }

        let petRect = CGRect(x: (bounds.width - petSize) / 2, y: topSpace,
                             width: petSize, height: petSize)
        drawPet(in: petRect, ctx: ctx)

        let pillRect = CGRect(x: 6, y: topSpace + petSize + 6, width: bounds.width - 12, height: pillHeight)
        drawPill(statusText, in: pillRect, ctx: ctx)
    }

    private func drawPet(in rect: CGRect, ctx: CGContext) {
        let elapsed = Date().timeIntervalSince(stateSince)
        if let img = sprites.frame(for: state, elapsed: elapsed) {
            let iw = CGFloat(img.width)
            let ih = CGFloat(img.height)
            let scale = min(rect.width / iw, rect.height / ih)
            let r = CGRect(x: rect.midX - iw * scale / 2, y: rect.midY - ih * scale / 2,
                           width: iw * scale, height: ih * scale)
            ctx.saveGState()
            ctx.translateBy(x: r.midX, y: r.midY)
            ctx.scaleBy(x: flip, y: -1)
            ctx.draw(img, in: CGRect(x: -r.width / 2, y: -r.height / 2, width: r.width, height: r.height))
            ctx.restoreGState()
        } else {
            let emoji = NSAttributedString(string: "🐳", attributes: [
                .font: NSFont.systemFont(ofSize: petSize * 0.62),
            ])
            let size = emoji.size()
            emoji.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
        }
    }

    private func drawPill(_ text: String, in rect: CGRect, ctx: CGContext) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
        NSColor(calibratedWhite: 1, alpha: 0.92).setFill()
        path.fill()
        NSColor(calibratedWhite: 0.78, alpha: 1).setStroke()
        path.lineWidth = 1
        path.stroke()
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 0.12, alpha: 1),
            .paragraphStyle: style,
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let textSize = str.size()
        let textRect = CGRect(x: rect.minX + 8,
                              y: rect.midY - textSize.height / 2,
                              width: max(10, rect.width - 16),
                              height: textSize.height)
        str.draw(in: textRect)
    }

    private func drawBubble(_ text: String, in ctx: CGContext) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor(calibratedWhite: 0.95, alpha: 1),
            .paragraphStyle: style,
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let textSize = str.size()
        let padX: CGFloat = 10
        let padY: CGFloat = 5
        let w = min(bounds.width - 12, textSize.width + padX * 2)
        let h = textSize.height + padY * 2
        let rect = CGRect(x: (bounds.width - w) / 2, y: 4, width: w, height: h)
        let path = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
        NSColor(calibratedWhite: 0.09, alpha: 0.94).setFill()
        path.fill()
        let textRect = CGRect(x: rect.minX + padX / 2,
                              y: rect.midY - textSize.height / 2,
                              width: max(10, rect.width - padX),
                              height: textSize.height)
        str.draw(in: textRect)
        ctx.setFillColor(NSColor(calibratedWhite: 0.09, alpha: 0.94).cgColor)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: rect.midX - 5, y: rect.maxY))
        ctx.addLine(to: CGPoint(x: rect.midX + 5, y: rect.maxY))
        ctx.addLine(to: CGPoint(x: rect.midX, y: rect.maxY + 5))
        ctx.closePath()
        ctx.fillPath()
    }
}

// MARK: - 设置面板

final class SettingsView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14)
        NSColor(calibratedWhite: 1, alpha: 0.97).setFill()
        path.fill()
        NSColor(calibratedWhite: 0.78, alpha: 1).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

final class SettingsPanel: NSWindow {
    var onSizeChange: ((CGFloat) -> Void)?
    var onOpacityChange: ((CGFloat) -> Void)?
    var onSleepChange: ((TimeInterval) -> Void)?
    var onFocusAppChange: ((String) -> Void)?
    var onLaunchAtLoginChange: ((Bool) -> Void)?
    var onFocusHarness: (() -> Void)?
    var onQuit: (() -> Void)?

    private let sizeSlider = NSSlider(value: 160, minValue: 100, maxValue: 220, target: nil, action: nil)
    private let sizeLabel = NSTextField(labelWithString: "160px")
    private let opacitySlider = NSSlider(value: 1, minValue: 0.5, maxValue: 1, target: nil, action: nil)
    private let opacityLabel = NSTextField(labelWithString: "100%")
    private let sleepPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let focusAppField = NSTextField(string: "DSH Desktop")
    private let autostartCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "DSH: …")
    private var baseString = ""

    init() {
        let w: CGFloat = 300
        let h: CGFloat = 274
        super.init(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                   styleMask: [.borderless],
                   backing: .buffered,
                   defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let content = SettingsView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        contentView = content
        buildControls(in: content)
    }

    private func label(_ text: String, size: CGFloat = 11) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = NSFont.systemFont(ofSize: size, weight: .medium)
        l.textColor = NSColor(calibratedWhite: 0.12, alpha: 1)
        return l
    }

    private func buildControls(in content: NSView) {
        let margin: CGFloat = 16
        let rowH: CGFloat = 26

        let title = label(l("🐳 桌宠设置", "🐳 Pet Settings"), size: 13)
        title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        title.frame = NSRect(x: margin, y: 12, width: 220, height: 20)
        content.addSubview(title)

        let closeBtn = NSButton(title: "✕", target: self, action: #selector(closePanel))
        closeBtn.isBordered = false
        closeBtn.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        closeBtn.contentTintColor = NSColor(calibratedWhite: 0.35, alpha: 1)
        closeBtn.frame = NSRect(x: content.bounds.width - 36, y: 12, width: 24, height: 20)
        content.addSubview(closeBtn)

        var y: CGFloat = 46

        let sizeTitle = label(l("大小", "Size"))
        sizeTitle.frame = NSRect(x: margin, y: y, width: 62, height: rowH)
        content.addSubview(sizeTitle)
        sizeSlider.frame = NSRect(x: margin + 68, y: y + 4, width: 130, height: 20)
        sizeSlider.target = self
        sizeSlider.action = #selector(sizeChanged)
        content.addSubview(sizeSlider)
        sizeLabel.frame = NSRect(x: margin + 204, y: y, width: 80, height: rowH)
        sizeLabel.alignment = .right
        content.addSubview(sizeLabel)
        y += 30

        let opTitle = label(l("透明度", "Opacity"))
        opTitle.frame = NSRect(x: margin, y: y, width: 62, height: rowH)
        content.addSubview(opTitle)
        opacitySlider.frame = NSRect(x: margin + 68, y: y + 4, width: 130, height: 20)
        opacitySlider.target = self
        opacitySlider.action = #selector(opacityChanged)
        content.addSubview(opacitySlider)
        opacityLabel.frame = NSRect(x: margin + 204, y: y, width: 80, height: rowH)
        opacityLabel.alignment = .right
        content.addSubview(opacityLabel)
        y += 30

        let sleepTitle = label(l("入睡时间", "Sleep after"))
        sleepTitle.frame = NSRect(x: margin, y: y, width: 62, height: rowH)
        content.addSubview(sleepTitle)
        sleepPopup.frame = NSRect(x: margin + 68, y: y + 1, width: 130, height: 24)
        sleepPopup.removeAllItems()
        sleepPopup.addItems(withTitles: [
            l("30 秒", "30s"), l("1 分钟", "1 min"), l("2 分钟", "2 min"),
            l("5 分钟", "5 min"), l("永不", "Never"),
        ])
        sleepPopup.target = self
        sleepPopup.action = #selector(sleepChanged)
        content.addSubview(sleepPopup)
        y += 30

        let focusTitle = label(l("回窗口应用", "Focus app"))
        focusTitle.frame = NSRect(x: margin, y: y, width: 62, height: rowH)
        content.addSubview(focusTitle)
        focusAppField.frame = NSRect(x: margin + 68, y: y + 2, width: 130, height: 22)
        focusAppField.font = NSFont.systemFont(ofSize: 11)
        focusAppField.target = self
        focusAppField.action = #selector(focusAppChanged)
        content.addSubview(focusAppField)
        let focusHint = label(l("浏览器自动兜底", "Browsers auto-fallback"), size: 9)
        focusHint.textColor = NSColor(calibratedWhite: 0.45, alpha: 1)
        focusHint.frame = NSRect(x: margin + 204, y: y, width: 88, height: rowH)
        content.addSubview(focusHint)
        y += 30

        autostartCheck.frame = NSRect(x: margin, y: y, width: 220, height: rowH)
        autostartCheck.target = self
        autostartCheck.action = #selector(autostartChanged)
        autostartCheck.attributedTitle = NSAttributedString(string: l("开机自启动", "Launch at login"), attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 0.12, alpha: 1),
        ])
        content.addSubview(autostartCheck)
        y += 30

        statusLabel.frame = NSRect(x: margin, y: y, width: content.bounds.width - margin * 2, height: 18)
        statusLabel.font = NSFont.systemFont(ofSize: 10)
        statusLabel.textColor = NSColor(calibratedWhite: 0.35, alpha: 1)
        content.addSubview(statusLabel)
        y += 24

        let focusBtn = NSButton(title: "🖥️", target: self, action: #selector(focusPressed))
        focusBtn.bezelStyle = .rounded
        focusBtn.controlSize = .small
        focusBtn.attributedTitle = NSAttributedString(string: l("🖥️ 回到任务窗口", "🖥️ Back to task window"), attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 0.1, alpha: 1),
        ])
        focusBtn.frame = NSRect(x: margin, y: y, width: 138, height: 26)
        content.addSubview(focusBtn)

        let quitBtn = NSButton(title: "📴", target: self, action: #selector(quitPressed))
        quitBtn.bezelStyle = .rounded
        quitBtn.controlSize = .small
        quitBtn.attributedTitle = NSAttributedString(string: l("📴 退出桌宠", "📴 Quit pet"), attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 0.1, alpha: 1),
        ])
        quitBtn.frame = NSRect(x: margin + 146, y: y, width: content.bounds.width - margin * 2 - 146, height: 26)
        content.addSubview(quitBtn)
    }

    func setValues(size: CGFloat, opacity: CGFloat, sleepMs: TimeInterval, focusApp: String,
                   launchAtLogin: Bool, connected: Bool, base: String) {
        sizeSlider.doubleValue = Double(size)
        sizeLabel.stringValue = "\(Int(size))px"
        opacitySlider.doubleValue = Double(opacity)
        opacityLabel.stringValue = "\(Int(opacity * 100))%"
        let sleepIdx: Int
        switch sleepMs {
        case ..<31: sleepIdx = 0
        case ..<61: sleepIdx = 1
        case ..<121: sleepIdx = 2
        case ..<301: sleepIdx = 3
        default: sleepIdx = 4
        }
        sleepPopup.selectItem(at: sleepIdx)
        focusAppField.stringValue = focusApp
        autostartCheck.state = launchAtLogin ? .on : .off
        baseString = base
        statusLabel.stringValue = "DSH: \(base) · \(connected ? l("已连接", "connected") : l("离线", "offline"))"
    }

    func updateStatus(connected: Bool) {
        statusLabel.stringValue = "DSH: \(baseString) · \(connected ? l("已连接", "connected") : l("离线", "offline"))"
    }

    @objc private func sizeChanged() {
        let v = CGFloat(sizeSlider.doubleValue)
        sizeLabel.stringValue = "\(Int(v))px"
        onSizeChange?(v)
    }

    @objc private func opacityChanged() {
        let v = CGFloat(opacitySlider.doubleValue)
        opacityLabel.stringValue = "\(Int(v * 100))%"
        onOpacityChange?(v)
    }

    @objc private func sleepChanged() {
        let values: [TimeInterval] = [30, 60, 120, 300, -1]
        let idx = sleepPopup.indexOfSelectedItem
        onSleepChange?(values[max(0, min(values.count - 1, idx))])
    }

    @objc private func focusAppChanged() {
        let v = focusAppField.stringValue.trimmingCharacters(in: .whitespaces)
        if !v.isEmpty { onFocusAppChange?(v) }
    }

    @objc private func autostartChanged() {
        onLaunchAtLoginChange?(autostartCheck.state == .on)
    }

    @objc private func focusPressed() { onFocusHarness?() }
    @objc private func quitPressed() { onQuit?() }
    @objc private func closePanel() { close() }
}

// MARK: - 窗口控制器

final class CompanionController: NSObject {
    let base: String
    let window: NSWindow
    let view: PetView
    let sprites: SpriteManager
    let settings: SettingsPanel

    private var pollTimer: Timer?
    private var sessionsTimer: Timer?
    private var presenceTimer: Timer?
    private var animTimer: Timer?
    private var lastTurnWindow = false
    private var idleSince = Date()
    private var sleeping = false
    private var levelText = ""
    private var connected = false
    private var sleepAfterMs: TimeInterval = 60
    private var currentOpacity: CGFloat = 1
    private var focusApp = "DSH Desktop"

    init(base: String, size: CGFloat) {
        self.base = base
        self.sprites = SpriteManager(base: base)
        self.view = PetView(petSize: size, sprites: sprites)
        self.settings = SettingsPanel()

        let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let w = view.bounds.width
        let h = view.bounds.height
        var origin = NSPoint(x: vf.maxX - w - 24, y: vf.minY + 24)
        if let saved = UserDefaults.standard.string(forKey: UD_POS) {
            let parts = saved.split(separator: ",")
            if parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) {
                let p = NSPoint(x: x, y: y)
                if vf.contains(NSPoint(x: p.x + w / 2, y: p.y + h / 2)) { origin = p }
            }
        }

        window = NSWindow(contentRect: NSRect(origin: origin, size: NSSize(width: w, height: h)),
                          styleMask: [.borderless],
                          backing: .buffered,
                          defer: false)
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.animationBehavior = .none
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isReleasedWhenClosed = false
        window.contentView = view
        super.init()

        sprites.onUpdate = { [weak self] in self?.view.needsDisplay = true }
        wireSettings()
    }

    private func wireSettings() {
        settings.onSizeChange = { [weak self] size in self?.applySize(size) }
        settings.onOpacityChange = { [weak self] opacity in self?.applyOpacity(opacity) }
        settings.onSleepChange = { [weak self] ms in
            self?.sleepAfterMs = ms
            UserDefaults.standard.set(ms, forKey: UD_SLEEP_MS)
        }
        settings.onFocusAppChange = { [weak self] name in
            self?.focusApp = name
            UserDefaults.standard.set(name, forKey: UD_FOCUS_APP)
        }
        settings.onLaunchAtLoginChange = { [weak self] on in self?.setLaunchAtLogin(on) }
        settings.onFocusHarness = { [weak self] in
            self?.settings.close()
            self?.focusHarness()
        }
        settings.onQuit = { [weak self] in self?.quit() }
    }

    func start() {
        if let size = UserDefaults.standard.object(forKey: UD_SIZE) as? NSNumber {
            applySize(CGFloat(size.doubleValue))
        }
        if let op = UserDefaults.standard.object(forKey: UD_OPACITY) as? NSNumber {
            applyOpacity(CGFloat(op.doubleValue))
        }
        if let sleep = UserDefaults.standard.object(forKey: UD_SLEEP_MS) as? NSNumber {
            sleepAfterMs = sleep.doubleValue
        }
        if let app = UserDefaults.standard.string(forKey: UD_FOCUS_APP), !app.isEmpty {
            focusApp = app
        }

        sprites.load()
        httpPost("\(base)\(ROUTE_PREFIX)/presence", ["online": true])
        pollState()
        pollSessions()
        pollTimer = Timer.scheduledTimer(withTimeInterval: STATE_POLL_INTERVAL, repeats: true) { [weak self] _ in
            self?.pollState()
        }
        sessionsTimer = Timer.scheduledTimer(withTimeInterval: SESSIONS_POLL_INTERVAL, repeats: true) { [weak self] _ in
            self?.pollSessions()
        }
        presenceTimer = Timer.scheduledTimer(withTimeInterval: PRESENCE_INTERVAL, repeats: true) { [weak self] _ in
            self?.heartbeat()
        }
        if let t = presenceTimer { RunLoop.main.add(t, forMode: .common) }
        animTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.view.dragging { return }
            if self.view.state == "idle" || self.view.state == "sleep" {
                let timeout = self.sleepAfterMs
                if self.view.state == "idle" && timeout > 0 && Date().timeIntervalSince(self.idleSince) > timeout {
                    self.sleeping = true
                    self.setPetState("sleep")
                }
            } else {
                self.idleSince = Date()
            }
            self.view.needsDisplay = true
        }
        window.orderFrontRegardless()
    }

    // MARK: 尺寸 / 透明度

    func applySize(_ size: CGFloat) {
        view.applySize(size)
        window.setContentSize(view.frame.size)
        UserDefaults.standard.set(Double(size), forKey: UD_SIZE)
        syncWindowWidth()
        view.needsDisplay = true
    }

    func applyOpacity(_ opacity: CGFloat) {
        currentOpacity = opacity
        window.alphaValue = opacity
        UserDefaults.standard.set(Double(opacity), forKey: UD_OPACITY)
    }

    // 状态条文字动态宽度（右缘锚定，向左生长）
    func syncWindowWidth() {
        guard !view.dragging else { return }
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let textSize = NSAttributedString(string: view.statusText, attributes: [.font: font]).size()
        let minW = view.petSize + 24
        let targetW = max(minW, textSize.width + 16 + 12)
        let curW = window.frame.width
        guard abs(targetW - curW) > 2 else { return }
        var frame = window.frame
        frame.origin.x = frame.maxX - targetW
        frame.size.width = targetW
        window.setFrame(frame, display: true)
    }

    // MARK: 开机自启动（LaunchAgent）

    private func launchAgentPath() -> String {
        NSHomeDirectory() + "/Library/LaunchAgents/com.dsh-desktop-pet.companion.plist"
    }

    func isLaunchAtLogin() -> Bool {
        FileManager.default.fileExists(atPath: launchAgentPath())
    }

    func setLaunchAtLogin(_ on: Bool) {
        let path = launchAgentPath()
        let uid = getuid()
        let label = "com.dsh-desktop-pet.companion"
        if on {
            let bin = URL(fileURLWithPath: CommandLine.arguments[0]).path
            let dict: [String: Any] = [
                "Label": label,
                "ProgramArguments": [bin, "--base", base, "--size", "\(Int(view.petSize))"],
                "RunAtLoad": true,
                "KeepAlive": false,
                "StandardOutPath": "/tmp/dsh-desktop-pet.log",
                "StandardErrorPath": "/tmp/dsh-desktop-pet.log",
            ]
            if let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0) {
                try? FileManager.default.createDirectory(atPath: NSHomeDirectory() + "/Library/LaunchAgents",
                                                         withIntermediateDirectories: true)
                try? data.write(to: URL(fileURLWithPath: path))
            }
            try? Process.run(URL(fileURLWithPath: "/bin/launchctl"),
                             arguments: ["bootstrap", "gui/\(uid)", path])
        } else {
            try? Process.run(URL(fileURLWithPath: "/bin/launchctl"),
                             arguments: ["bootout", "gui/\(uid)/\(label)"])
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    // MARK: 状态轮询

    private func pollState() {
        httpGet("\(base)\(ROUTE_PREFIX)/state") { [weak self] data in
            guard let self = self else { return }
            guard let data = data,
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                self.connected = false
                self.view.statusText = l("📡 离线…", "📡 Offline…")
                if !self.view.dragging {
                    self.view.needsDisplay = true
                    self.syncWindowWidth()
                    if self.settings.isVisible { self.settings.updateStatus(connected: false) }
                }
                return
            }
            self.connected = true
            let activity = json["activity"] as? [String: Any] ?? [:]
            let name = activity["name"] as? String ?? "idle"
            let sessionThink = activity["sessionThink"] as? Bool ?? false
            let sessionWait = activity["sessionWait"] as? Bool ?? false
            let turnUntil = activity["turnCompletedUntil"] as? Double ?? 0
            let turnWindow = turnUntil > Date().timeIntervalSince1970 * 1000

            let pet = json["pet"] as? [String: Any] ?? [:]
            let level = pet["level"] as? Int ?? 1
            let stats = pet["stats"] as? [String: Any] ?? [:]
            let tasksDone = stats["tasksDone"] as? Int ?? 0
            self.levelText = "Lv.\(level) · \(tasksDone) \(l("任务", "tasks"))"

            if turnWindow && !self.lastTurnWindow {
                if !self.view.dragging {
                    self.showBubble(l("🎉 任务完成！", "🎉 Task done!"))
                    self.setPetState("celebrate")
                }
            }
            self.lastTurnWindow = turnWindow

            if !self.view.dragging {
                var next = name
                if name == "celebrate" || name == "error" || name == "disappointed" || name == "welcome" {
                    next = name
                } else if sessionWait {
                    next = "wait"
                } else if sessionThink {
                    next = "think"
                } else if name == "working" {
                    next = "working"
                } else if name == "idle" {
                    next = self.sleeping ? "sleep" : "idle"
                }
                self.setPetState(next)

                let text: String
                switch next {
                case "wait": text = l("⏸ 等待你的批准", "⏸ Waiting for approval")
                case "think": text = l("🤔 思考中…", "🤔 Thinking…")
                case "working": text = l("⚙️ 正在执行任务…", "⚙️ Running task…")
                case "error": text = l("😵 任务出错了…", "😵 Task failed…")
                case "disappointed": text = l("😢 有点失落…", "😢 A bit down…")
                case "celebrate": text = l("🎉 任务完成！", "🎉 Task done!")
                case "welcome": text = l("👋 欢迎回来！", "👋 Welcome back!")
                case "sleep": text = l("💤 睡着了…", "💤 Sleeping…")
                default: text = l("☕ 待命中 · ", "☕ Idle · ") + self.levelText
                }
                self.view.statusText = text
            }
            if !self.view.dragging {
                self.syncWindowWidth()
                if self.settings.isVisible { self.settings.updateStatus(connected: true) }
                self.view.needsDisplay = true
            }
        }
    }

    private func pollSessions() {
        httpGet("\(base)\(ROUTE_PREFIX)/sessions") { [weak self] data in
            guard let self = self, let data = data,
                  let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return }
            let active = list.filter { ($0["activity"] as? String) != "done" }
            guard let latest = active.max(by: { (a, b) -> Bool in
                (a["since"] as? Double ?? 0) < (b["since"] as? Double ?? 0)
            }), let act = latest["activity"] as? String else {
                if !self.view.dragging && (self.view.state == "think" || self.view.state == "wait") {
                    self.setPetState("idle")
                    self.view.statusText = l("☕ 待命中 · ", "☕ Idle · ") + self.levelText
                    self.syncWindowWidth()
                    self.view.needsDisplay = true
                }
                return
            }
            if self.view.dragging { return }
            let title = latest["title"] as? String
            if act.hasPrefix("tool:") {
                let tool = String(act.dropFirst("tool:".count))
                self.view.statusText = l("🛠️ 正在调用 ", "🛠️ Calling ") + tool
            } else if act == "thinking" {
                if let title = title, !title.isEmpty {
                    self.view.statusText = l("🤔 思考中…「", "🤔 Thinking…“") + title + "”"
                } else {
                    self.view.statusText = l("🤔 思考中…", "🤔 Thinking…")
                }
            } else if act == "waiting" {
                self.view.statusText = l("⏸ 等待你的批准", "⏸ Waiting for approval")
            }
            self.syncWindowWidth()
            self.view.needsDisplay = true
        }
    }

    private func heartbeat() {
        httpPost("\(base)\(ROUTE_PREFIX)/presence", ["online": true])
    }

    // MARK: 显示辅助

    func setPetState(_ name: String) {
        guard view.state != name else { return }
        view.state = name
        view.stateSince = Date()
        if name == "idle" { idleSince = Date() }
        if name == "sleep" { sleeping = true }
        if name != "sleep" && name != "idle" { sleeping = false }
        view.needsDisplay = true
    }

    func showBubble(_ text: String) {
        view.bubbleText = text
        view.bubbleUntil = Date().addingTimeInterval(BUBBLE_MS)
        view.needsDisplay = true
    }

    // MARK: 互动

    func interact(_ action: String) {
        httpPost("\(base)\(ROUTE_PREFIX)/interact", ["action": action]) { [weak self] data in
            guard let self = self else { return }
            let reply: String
            if let data = data,
               let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let r = json["reply"] as? String {
                reply = r
            } else {
                reply = action == "feed"
                    ? l("「啊呜——谢谢投喂！」", "“Yum — thanks for the treat!”")
                    : l("「玩得好开心～」", "“That was fun!”")
            }
            self.showBubble(reply)
        }
        setPetState(action == "feed" ? "eat" : "play")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self = self, self.view.state == (action == "feed" ? "eat" : "play") else { return }
            self.setPetState("idle")
        }
    }

    // MARK: 设置面板

    func toggleSettings(relativeTo view: NSView) {
        if settings.isVisible {
            settings.close()
            return
        }
        settings.setValues(size: self.view.petSize, opacity: currentOpacity,
                           sleepMs: sleepAfterMs, focusApp: focusApp,
                           launchAtLogin: isLaunchAtLogin(),
                           connected: connected, base: base)
        let petFrame = window.frame
        let panelSize = settings.frame.size
        var origin = NSPoint(x: petFrame.maxX + 12, y: petFrame.midY - panelSize.height / 2)
        if let vf = NSScreen.main?.visibleFrame {
            if origin.x + panelSize.width > vf.maxX {
                origin.x = petFrame.minX - panelSize.width - 12
            }
            origin.x = max(vf.minX + 4, origin.x)
            origin.y = min(max(vf.minY + 4, origin.y), vf.maxY - panelSize.height - 4)
        }
        settings.setFrameOrigin(origin)
        settings.orderFrontRegardless()
    }

    // MARK: 回到任务窗口（应用可配置 + 浏览器自动兜底）

    func focusHarness() {
        showBubble(l("🖱️ 回到任务窗口…", "🖱️ Back to task window…"))
        let ws = NSWorkspace.shared
        let target = focusApp

        // 1) 配置的应用（默认 DSH Desktop）
        if let app = ws.runningApplications.first(where: {
            $0.localizedName == target
                || ($0.localizedName?.lowercased() == target.lowercased())
                || ($0.bundleIdentifier?.lowercased().contains(target.lowercased()) ?? false)
        }) {
            if !app.activate(options: [.activateAllWindows]) { openApp(target) }
            return
        }
        // 2) 浏览器兜底（用实际 base 匹配标签页）
        let browsers = [("Google Chrome", "com.google.Chrome"), ("Safari", "com.apple.Safari")]
        for (name, bid) in browsers {
            if let b = ws.runningApplications.first(where: { $0.bundleIdentifier == bid }) {
                if !b.activate(options: [.activateAllWindows]) { openApp(name) }
                switchToHarnessTab(name)
                return
            }
        }
        // 3) 兜底拉起配置的应用
        openApp(target)
    }

    private func openApp(_ name: String) {
        try? Process.run(URL(fileURLWithPath: "/usr/bin/open"), arguments: ["-a", name])
    }

    // 用实际 base 的主机:端口匹配 harness 标签页
    private func switchToHarnessTab(_ appName: String) {
        var match = "127.0.0.1:3080"
        if let u = URL(string: base), let port = u.port {
            match = "\(u.host ?? "127.0.0.1"):\(port)"
        }
        let localhostMatch = "localhost:" + (URL(string: base)?.port.map(String.init) ?? "3080")
        let script = """
        tell application "\(appName)"
          repeat with w in windows
            repeat with t in tabs of w
              if (URL of t contains "\(match)") or (URL of t contains "\(localhostMatch)") then
                set active tab index of w to (index of t)
                set index of w to 1
                return
              end if
            end repeat
          end repeat
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
    }

    func quit() {
        sendOffline()
        NSApp.terminate(nil)
    }

    func sendOffline() {
        let curl = "/usr/bin/curl"
        let args = ["-s", "-m", "2", "-X", "POST", "-H", "content-type: application/json",
                    "-d", "{\"online\":false}", "\(base)\(ROUTE_PREFIX)/presence"]
        try? Process.run(URL(fileURLWithPath: curl), arguments: args)
    }
}

// MARK: - 视图交互（系统级拖动 / 单击 / 右键设置）

extension PetView {
    private var controller: CompanionController? {
        (NSApp.delegate as? AppDelegate)?.controller
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if snapshotImage == nil, let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: rep)
            let img = NSImage(size: bounds.size)
            img.addRepresentation(rep)
            snapshotImage = img
            needsDisplay = true
        }
        pressStartOrigin = window?.frame.origin
        pressMaxDist = 0
        pressFinalized = false
        let startMouse = NSEvent.mouseLocation
        window?.orderFrontRegardless()
        dragging = true
        // performDrag 在 macOS 26 上异步返回：用本地监视器在 leftMouseUp 时做最终判定
        var monitor: Any?
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] ev in
            guard let self = self else { return ev }
            let p = NSEvent.mouseLocation
            self.pressMaxDist = max(self.pressMaxDist, abs(p.x - startMouse.x) + abs(p.y - startMouse.y))
            if ev.type == .leftMouseUp {
                if let m = monitor { NSEvent.removeMonitor(m) }
                self.activeMonitor = nil
                self.finalizePress(clickCount: ev.clickCount)
            }
            return ev
        }
        activeMonitor = monitor
        window?.performDrag(with: event)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self, !self.pressFinalized, NSEvent.pressedMouseButtons == 0 else { return }
            if let m = self.activeMonitor { NSEvent.removeMonitor(m) }
            self.activeMonitor = nil
            self.finalizePress(clickCount: event.clickCount)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if !pressFinalized {
            if let m = activeMonitor { NSEvent.removeMonitor(m) }
            activeMonitor = nil
            finalizePress(clickCount: event.clickCount)
        }
    }

    private func finalizePress(clickCount: Int) {
        guard !pressFinalized else { return }
        pressFinalized = true
        dragging = false
        var moved = pressMaxDist > 6
        if let w = window, let s = pressStartOrigin {
            moved = moved || (abs(w.frame.origin.x - s.x) + abs(w.frame.origin.y - s.y) > 6)
        }
        if moved {
            if let origin = window?.frame.origin {
                UserDefaults.standard.set("\(Int(origin.x)),\(Int(origin.y))", forKey: UD_POS)
            }
            state = "idle"
            stateSince = Date()
        } else if clickCount >= 2 {
            controller?.interact("feed")
        } else {
            controller?.focusHarness()
        }
        if snapshotImage != nil {
            snapshotImage = nil
            needsDisplay = true
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        controller?.toggleSettings(relativeTo: self)
    }
}

// MARK: - App 入口

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: CompanionController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let parsed = parseArgs()
        langMode = parsed.lang
        guard acquireSingleInstanceLock() else { exit(0) }
        // 实例发现：--base 优先，否则探测 DSH_WEB_PORT / 62942 / 3080
        let base = resolveBase(explicit: parsed.base)
        let c = CompanionController(base: base, size: parsed.size)
        controller = c
        c.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.sendOffline()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
