//
//  App.swift
//  DimBar — menu bar UI.
//

import AppKit
import Carbon.HIToolbox
import IOKit.pwr_mgt
import ServiceManagement


// MARK: - Debug logging
//
// `DIMBAR_LOG=1` writes lifecycle diagnostics to /tmp/dimbar.log.

enum DebugLog {
    static let enabled = ProcessInfo.processInfo.environment["DIMBAR_LOG"] != nil

    static func write(_ message: String) {
        let line = "[\(Date().timeIntervalSince1970)] \(message)\n"
        NSLog("DimBar: %@", message)
        guard enabled else { return }
        let url = URL(fileURLWithPath: "/tmp/dimbar.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Coalescing writer
//
// DDC writes take ~20-30 ms each. A slider drag produces far more events than
// that, so we keep only the newest requested value and apply it as soon as the
// previous write finishes.

final class BrightnessWriter {
    private let queue = DispatchQueue(label: "com.dimbar.ddc")
    private var pending: Int?
    private var busy = false
    private let bus: DDCBus

    var onApplied: ((Int) -> Void)?

    init(bus: DDCBus) {
        self.bus = bus
    }

    func submit(_ percent: Int) {
        queue.async {
            self.pending = percent
            guard !self.busy else { return }
            self.busy = true
            while let next = self.pending {
                self.pending = nil
                self.bus.setBrightness(percent: next)
                DispatchQueue.main.async { self.onApplied?(next) }
            }
            self.busy = false
        }
    }

    func read(_ completion: @escaping (Int?) -> Void) {
        queue.async {
            let value = self.bus.read(vcp: VCP.brightness)?.percent
            DispatchQueue.main.async { completion(value) }
        }
    }
}

// MARK: - Global hotkeys
//
// Carbon hotkeys need no accessibility / input-monitoring permission,
// which is why DimBar uses them instead of tapping the brightness keys.

final class HotkeyManager {
    static let shared = HotkeyManager()

    var onStep: ((Int) -> Void)?

    private var refs: [EventHotKeyRef] = []
    private var installed = false

    private static let signature: OSType = 0x44494D42  // 'DIMB'

    func install() {
        guard !installed else { return }
        installed = true

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let handler: EventHandlerUPP = { _, event, _ in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event,
                                           EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID),
                                           nil,
                                           MemoryLayout<EventHotKeyID>.size,
                                           nil,
                                           &hotKeyID)
            guard status == noErr, hotKeyID.signature == HotkeyManager.signature else {
                return OSStatus(eventNotHandledErr)
            }
            let delta: Int = hotKeyID.id == 1 ? 10 : -10
            DispatchQueue.main.async { HotkeyManager.shared.onStep?(delta) }
            return noErr
        }

        InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventType, nil, nil)

        register(keyCode: UInt32(kVK_UpArrow), id: 1)
        register(keyCode: UInt32(kVK_DownArrow), id: 2)
    }

    private func register(keyCode: UInt32, id: UInt32) {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: HotkeyManager.signature, id: id)
        let status = RegisterEventHotKey(keyCode,
                                         UInt32(controlKey | optionKey),
                                         hotKeyID,
                                         GetApplicationEventTarget(),
                                         0,
                                         &ref)
        if status == noErr, let ref {
            refs.append(ref)
            DebugLog.write("hotkey id=\(id) registered")
        } else {
            NSLog("DimBar: failed to register hotkey id=%u (status %d)", id, status)
        }
    }
}

// MARK: - Login item
//
// SMAppService is the sanctioned API (it also shows up in System Settings ▸
// General ▸ Login Items). If that refuses to register — usually a signing
// problem — fall back to a plain LaunchAgent, which launchd picks up at login.

enum LoginItem {
    static let label = "com.dimbar.agent"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        let status = SMAppService.mainApp.status
        if status == .enabled || status == .requiresApproval { return true }
        return FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func enable() -> Bool {
        do {
            try SMAppService.mainApp.register()
            if SMAppService.mainApp.status == .enabled {
                DebugLog.write("login item: SMAppService registered")
                return true
            }
            if SMAppService.mainApp.status == .requiresApproval {
                DebugLog.write("login item: SMAppService needs approval in System Settings")
                return true
            }
            DebugLog.write("login item: SMAppService status=\(SMAppService.mainApp.status.rawValue)")
        } catch {
            DebugLog.write("login item: SMAppService failed (\(error)); falling back to LaunchAgent")
        }
        return enableLaunchAgent()
    }

    static func disable() -> Bool {
        if SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval {
            do { try SMAppService.mainApp.unregister() } catch {
                DebugLog.write("login item: SMAppService unregister failed (\(error))")
            }
        }
        return disableLaunchAgent()
    }

    // MARK: LaunchAgent fallback

    private static func enableLaunchAgent() -> Bool {
        guard let executable = Bundle.main.executablePath else { return false }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
        ]
        do {
            try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL)
            runLaunchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
            DebugLog.write("login item: LaunchAgent written to \(plistURL.path)")
            return true
        } catch {
            DebugLog.write("login item: LaunchAgent failed (\(error))")
            return false
        }
    }

    private static func disableLaunchAgent() -> Bool {
        guard FileManager.default.fileExists(atPath: plistURL.path) else { return true }
        runLaunchctl(["bootout", "gui/\(getuid())", plistURL.path])
        try? FileManager.default.removeItem(at: plistURL)
        DebugLog.write("login item: LaunchAgent removed")
        return true
    }

    private static func runLaunchctl(_ args: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}

// MARK: - Keep awake
//
// Holds power-management assertions so the Mac and the display stop idling to
// sleep. Assertions are scoped to this process: quit DimBar (or toggle off) and
// normal sleep behaviour returns immediately. No root, no pmset changes.

final class AwakeController {
    private static let preferenceKey = "keepAwake"

    private var assertions: [IOPMAssertionID] = []

    var isActive: Bool { !assertions.isEmpty }

    /// Restores the user's saved preference. Returns true if it is now active.
    @discardableResult
    func restorePreference() -> Bool {
        guard UserDefaults.standard.bool(forKey: Self.preferenceKey) else { return false }
        return enable()
    }

    @discardableResult
    func enable() -> Bool {
        guard assertions.isEmpty else { return true }

        let types = [
            kIOPMAssertionTypePreventUserIdleDisplaySleep,
            kIOPMAssertionTypePreventUserIdleSystemSleep,
        ]
        let reason = "DimBar is keeping the display awake" as CFString

        for type in types {
            var id: IOPMAssertionID = 0
            let status = IOPMAssertionCreateWithName(type as CFString,
                                                     IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                     reason,
                                                     &id)
            if status == kIOReturnSuccess {
                assertions.append(id)
            } else {
                DebugLog.write("keep awake: assertion \(type) failed (\(status))")
            }
        }

        UserDefaults.standard.set(isActive, forKey: Self.preferenceKey)
        DebugLog.write("keep awake: enabled with \(assertions.count) assertion(s)")
        return isActive
    }

    func disable() {
        for id in assertions {
            IOPMAssertionRelease(id)
        }
        assertions.removeAll()
        UserDefaults.standard.set(false, forKey: Self.preferenceKey)
        DebugLog.write("keep awake: disabled")
    }

    @discardableResult
    func toggle() -> Bool {
        if isActive {
            disable()
        } else {
            enable()
        }
        return isActive
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private var displays: [ExternalDisplay] = []
    private var writers: [CGDirectDisplayID: BrightnessWriter] = [:]
    private var percentCache: [CGDirectDisplayID: Int] = [:]

    private var sliders: [CGDirectDisplayID: NSSlider] = [:]
    private var labels: [CGDirectDisplayID: NSTextField] = [:]
    private var desiredPercent: [CGDirectDisplayID: Int] = [:]

    private var refreshScheduled = false
    private var titleResetWorkItem: DispatchWorkItem?

    private let awake = AwakeController()

    // MARK: lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        HotkeyManager.shared.onStep = { [weak self] delta in
            self?.step(delta)
        }
        HotkeyManager.shared.install()

        if awake.restorePreference() {
            updateStatusIcon()
        }

        CGDisplayRegisterReconfigurationCallback({ _, _, _ in
            DispatchQueue.main.async {
                guard let delegate = NSApp.delegate as? AppDelegate else { return }
                delegate.scheduleRefresh()
            }
        }, nil)

        let buttons = statusItem.button
        DebugLog.write("launched: statusItem length=\(statusItem.length) button=\(buttons != nil) image=\(buttons?.image != nil) window=\(buttons?.window != nil)")

        reloadDisplays()
        DebugLog.write("displays: \(displays.map { "\($0.name)/\($0.id)" })")

    }

    // MARK: display plumbing

    private func reloadDisplays() {
        displays = DisplayDiscovery.externalDisplays()

        var freshWriters: [CGDirectDisplayID: BrightnessWriter] = [:]
        for display in displays {
            if let existing = writers[display.id] {
                freshWriters[display.id] = existing
                continue
            }
            let writer = BrightnessWriter(bus: display.bus)
            writer.onApplied = { [weak self] percent in
                self?.percentCache[display.id] = percent
                self?.desiredPercent[display.id] = percent
                self?.updateSlider(for: display.id, percent: percent)
                self?.flashTitle("\(percent)%")
            }
            freshWriters[display.id] = writer
        }
        writers = freshWriters

        for display in displays {
            writers[display.id]?.read { [weak self] percent in
                guard let self, let percent, self.percentCache[display.id] == nil else { return }
                self.percentCache[display.id] = percent
                self.updateSlider(for: display.id, percent: percent)
            }
        }
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.refreshScheduled = false
            self?.reloadDisplays()
        }
    }

    private func displayUnderPointer() -> ExternalDisplay? {
        guard !displays.isEmpty else { return nil }
        if displays.count == 1 { return displays[0] }

        let mouse = NSEvent.mouseLocation
        for screen in NSScreen.screens where screen.frame.contains(mouse) {
            if let match = displays.first(where: { $0.id == screen.displayID }) {
                return match
            }
        }
        return displays[0]
    }

    private func step(_ delta: Int) {
        guard let display = displayUnderPointer(), let writer = writers[display.id] else { return }
        let current = desiredPercent[display.id] ?? percentCache[display.id] ?? 50
        let next = min(100, max(0, current + delta))
        desiredPercent[display.id] = next
        percentCache[display.id] = next
        updateSlider(for: display.id, percent: next)
        flashTitle("\(next)%")
        writer.submit(next)
    }

    // MARK: UI bits

    private func updateSlider(for id: CGDirectDisplayID, percent: Int) {
        sliders[id]?.doubleValue = Double(percent)
        labels[id]?.stringValue = "\(percent)%"
    }

    /// A filled sun means DimBar is holding the machine awake.
    private func updateStatusIcon() {
        let symbol = awake.isActive ? "sun.max.fill" : "sun.max"
        statusItem.button?.image = NSImage(systemSymbolName: symbol,
                                           accessibilityDescription: "DimBar")
        statusItem.button?.image?.isTemplate = true
    }

    private func flashTitle(_ text: String) {
        guard let button = statusItem.button else { return }
        titleResetWorkItem?.cancel()
        button.title = " " + text
        let work = DispatchWorkItem { [weak self] in
            self?.statusItem.button?.title = ""
        }
        titleResetWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        DebugLog.write("menuNeedsUpdate displays=\(displays.count)")
        if displays.isEmpty { reloadDisplays() }
        rebuild(menu)
        for display in displays {
            writers[display.id]?.read { [weak self] percent in
                guard let self, let percent else { return }
                self.percentCache[display.id] = percent
                self.updateSlider(for: display.id, percent: percent)
            }
        }
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        sliders.removeAll()
        labels.removeAll()

        if displays.isEmpty {
            let item = NSMenuItem(title: "No external display detected", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        for display in displays {
            let header = NSMenuItem(title: display.name, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

            let percent = percentCache[display.id] ?? 50
            menu.addItem(makeSliderItem(for: display, percent: percent))
            menu.addItem(.separator())
        }

        let up = NSMenuItem(title: "Brighter", action: #selector(brighter), keyEquivalent: "")
        up.keyEquivalent = String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
        up.keyEquivalentModifierMask = [.control, .option]
        up.target = self
        menu.addItem(up)

        let down = NSMenuItem(title: "Dimmer", action: #selector(dimmer), keyEquivalent: "")
        down.keyEquivalent = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
        down.keyEquivalentModifierMask = [.control, .option]
        down.target = self
        menu.addItem(down)

        let keepAwake = NSMenuItem(title: "Keep Awake", action: #selector(toggleAwake), keyEquivalent: "")
        keepAwake.state = awake.isActive ? .on : .off
        keepAwake.target = self
        keepAwake.toolTip = "Stop macOS from sleeping the display or the Mac while DimBar runs"
        menu.addItem(keepAwake)

        menu.addItem(.separator())

        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.state = LoginItem.isEnabled ? .on : .off
        login.target = self
        menu.addItem(login)

        let refresh = NSMenuItem(title: "Refresh Displays", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit DimBar", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func makeSliderItem(for display: ExternalDisplay, percent: Int) -> NSMenuItem {
        let item = NSMenuItem()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 34))

        let slider = NSSlider(value: Double(percent), minValue: 0, maxValue: 100,
                              target: self, action: #selector(sliderMoved(_:)))
        slider.frame = NSRect(x: 16, y: 5, width: 202, height: 24)
        slider.isContinuous = true
        slider.tag = Int(display.id)
        container.addSubview(slider)

        let label = NSTextField(labelWithString: "\(percent)%")
        label.frame = NSRect(x: 226, y: 8, width: 44, height: 18)
        label.alignment = .right
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        label.textColor = .secondaryLabelColor
        container.addSubview(label)

        item.view = container
        sliders[display.id] = slider
        labels[display.id] = label
        return item
    }

    // MARK: actions

    @objc private func sliderMoved(_ sender: NSSlider) {
        let id = CGDirectDisplayID(sender.tag)
        let percent = Int(sender.doubleValue.rounded())
        desiredPercent[id] = percent
        percentCache[id] = percent
        labels[id]?.stringValue = "\(percent)%"
        flashTitle("\(percent)%")
        writers[id]?.submit(percent)
    }

    @objc private func brighter() { step(10) }
    @objc private func dimmer() { step(-10) }

    @objc private func refreshNow() {
        percentCache.removeAll()
        reloadDisplays()
    }

    @objc private func toggleLogin() {
        if LoginItem.isEnabled {
            _ = LoginItem.disable()
        } else {
            _ = LoginItem.enable()
        }
    }

    @objc private func toggleAwake() {
        let active = awake.toggle()
        updateStatusIcon()
        flashTitle(active ? "Awake" : "Sleep")
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
