import AppKit
import CoreGraphics
import Foundation

private func macMicrophoneVoiceKeyCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
    context: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let context {
        Unmanaged<MacMicrophoneVoiceKeyMonitor>.fromOpaque(context)
            .takeUnretainedValue().observe(type: type, event: event)
    }
    // A listen-only tap never consumes or replaces the user's key.
    return Unmanaged.passUnretained(event)
}

/// Observes the configured physical voice modifier, including Fn, without registering it as a hotkey.
final class MacMicrophoneVoiceKeyMonitor {
    private enum TapLevel: String {
        case hid = "hid_head"
        case session = "session_head"

        var location: CGEventTapLocation {
            self == .hid ? .cghidEventTap : .cgSessionEventTap
        }
    }

    var onEdge: (Bool, TimeInterval) -> Void = { _, _ in }
    private let lock = NSLock()
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var tapLevel: TapLevel?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var watchdogTimer: Timer?
    private var generation: UInt64 = 0
    private var mode: VoiceKeyMode = .function
    private var lastDispatchedEdge: (pressed: Bool, uptime: TimeInterval)?

    @discardableResult
    func start(mode: VoiceKeyMode) -> Bool {
        lock.lock()
        let alreadyListening = (port != nil || globalMonitor != nil) && self.mode == mode
        lock.unlock()
        if alreadyListening { return true }
        stop()
        guard CGPreflightListenEventAccess() else {
            AppLogger.shared.write("MAC MICROPHONE KEY_MONITOR phase=failed reason=input_monitoring_permission")
            return false
        }
        lock.lock()
        self.mode = mode
        lock.unlock()

        // 1. 底层 HID / Session CGEventTap
        var tapInstalled = false
        if let installed = installTap(level: .hid, mode: mode) {
            store(installed, level: .hid, mode: mode)
            tapInstalled = true
        } else {
            AppLogger.shared.write(
                "MAC MICROPHONE KEY_MONITOR phase=fallback result=session_head reason=hid_unavailable"
            )
            if let installed = installTap(level: .session, mode: mode) {
                store(installed, level: .session, mode: mode)
                tapInstalled = true
            }
        }

        // 2. 高层 AppKit NSEvent 监视器（全局+本地，不被 WindowServer 超时挂起，永不失活）
        installAppKitMonitors(mode: mode)

        // 3. 启动看门狗定时器，每 3 秒检测底层 tap 状态
        startWatchdog()

        if !tapInstalled && globalMonitor == nil {
            AppLogger.shared.write("MAC MICROPHONE KEY_MONITOR phase=failed reason=all_monitors_unavailable")
            return false
        }
        return true
    }

    private func installAppKitMonitors(mode: VoiceKeyMode) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if let monitor = self.globalMonitor {
                NSEvent.removeMonitor(monitor)
                self.globalMonitor = nil
            }
            if let monitor = self.localMonitor {
                NSEvent.removeMonitor(monitor)
                self.localMonitor = nil
            }
            let currentGen = self.generation
            self.globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                guard let self else { return }
                self.handleNSEvent(event, generation: currentGen, source: "nsevent_global")
            }
            self.localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                guard let self else { return event }
                self.handleNSEvent(event, generation: currentGen, source: "nsevent_local")
                return event
            }
            self.lock.unlock()
            AppLogger.shared.write("MAC MICROPHONE KEY_MONITOR phase=appkit_monitors_started voice_key=\(mode.rawValue)")
        }
    }

    private func handleNSEvent(_ event: NSEvent, generation: UInt64, source: String) {
        lock.lock()
        guard generation == self.generation else {
            lock.unlock()
            return
        }
        let mode = self.mode
        lock.unlock()

        guard event.keyCode == mode.keyCode else { return }
        let pressed: Bool
        switch mode {
        case .function:
            pressed = event.modifierFlags.contains(.function)
        case .leftCommand, .rightCommand:
            pressed = event.modifierFlags.contains(.command)
        case .leftOption, .rightOption:
            pressed = event.modifierFlags.contains(.option)
        }

        let now = ProcessInfo.processInfo.systemUptime
        dispatchEdgeSafely(pressed: pressed, observedAt: now, generation: generation, source: source)
    }

    private func dispatchEdgeSafely(pressed: Bool, observedAt: TimeInterval, generation: UInt64, source: String) {
        lock.lock()
        guard generation == self.generation else {
            lock.unlock()
            return
        }
        // 50ms 去重，防止 CGEventTap 和 NSEventGlobalMonitor 同时派发相同边沿
        if let last = lastDispatchedEdge, last.pressed == pressed, abs(observedAt - last.uptime) < 0.05 {
            lock.unlock()
            return
        }
        lastDispatchedEdge = (pressed, observedAt)
        lock.unlock()

        AppLogger.shared.write("MAC MICROPHONE KEY_MONITOR phase=edge_observed source=\(source) pressed=\(pressed)")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let valid = self.generation == generation
            self.lock.unlock()
            if valid {
                self.onEdge(pressed, observedAt)
            }
        }
    }

    private func startWatchdog() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.watchdogTimer?.invalidate()
            self.watchdogTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                let port = self.port
                let mode = self.mode
                self.lock.unlock()
                guard let port else { return }
                if !CGEvent.tapIsEnabled(tap: port) {
                    AppLogger.shared.write("MAC MICROPHONE KEY_MONITOR phase=watchdog result=re-enabling_tap voice_key=\(mode.rawValue)")
                    CGEvent.tapEnable(tap: port, enable: true)
                }
            }
        }
    }

    private func installTap(
        level: TapLevel,
        mode: VoiceKeyMode
    ) -> (port: CFMachPort, source: CFRunLoopSource)? {
        guard let port = CGEvent.tapCreate(
            tap: level.location,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(1 << CGEventType.flagsChanged.rawValue),
            callback: macMicrophoneVoiceKeyCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            AppLogger.shared.write(
                "MAC MICROPHONE KEY_MONITOR phase=failed reason=tap_create_failed tap=\(level.rawValue)"
            )
            return nil
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            EventTapPort.release(port: port, source: nil)
            AppLogger.shared.write(
                "MAC MICROPHONE KEY_MONITOR phase=failed reason=run_loop_source_failed tap=\(level.rawValue)"
            )
            return nil
        }
        guard EventTapPort.activate(port: port, source: source) else {
            EventTapPort.release(port: port, source: source)
            AppLogger.shared.write(
                "MAC MICROPHONE KEY_MONITOR phase=failed reason=tap_activation_failed tap=\(level.rawValue)"
            )
            return nil
        }
        return (port, source)
    }

    private func store(
        _ installed: (port: CFMachPort, source: CFRunLoopSource),
        level: TapLevel,
        mode: VoiceKeyMode
    ) {
        lock.lock()
        port = installed.port
        source = installed.source
        tapLevel = level
        lock.unlock()
        AppLogger.shared.write(
            "MAC MICROPHONE KEY_MONITOR phase=started result=listening " +
                "voice_key=\(mode.rawValue) event_passthrough=true tap=\(level.rawValue)"
        )
    }

    func stop() {
        lock.lock()
        let port = self.port
        let source = self.source
        let tapLevel = self.tapLevel?.rawValue ?? "unknown"
        let globalMonitor = self.globalMonitor
        let localMonitor = self.localMonitor
        self.port = nil
        self.source = nil
        self.tapLevel = nil
        self.globalMonitor = nil
        self.localMonitor = nil
        self.lastDispatchedEdge = nil
        generation &+= 1
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.watchdogTimer?.invalidate()
            self?.watchdogTimer = nil
            if let globalMonitor {
                NSEvent.removeMonitor(globalMonitor)
            }
            if let localMonitor {
                NSEvent.removeMonitor(localMonitor)
            }
        }

        if port != nil || source != nil { EventTapPort.release(port: port, source: source) }
        if port != nil || globalMonitor != nil || localMonitor != nil {
            AppLogger.shared.write("MAC MICROPHONE KEY_MONITOR phase=completed result=stopped tap=\(tapLevel)")
        }
    }

    func observe(type: CGEventType, event: CGEvent) {
        lock.lock()
        let port = self.port
        let generation = self.generation
        let mode = self.mode
        let tapLevel = self.tapLevel?.rawValue ?? "unknown"
        lock.unlock()
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            AppLogger.shared.write("MAC MICROPHONE KEY_MONITOR phase=reenable_requested type=\(type.rawValue) tap=\(tapLevel)")
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return
        }
        if let observation = FnKeyDiagnostics.eventObservation(
            source: "hid_tap",
            tap: tapLevel,
            type: type,
            event: event
        ) {
            AppLogger.shared.write(observation)
        }
        if let observation = FnKeyDiagnostics.combinationObservation(
            source: "hid_tap",
            tap: tapLevel,
            type: type,
            event: event
        ) {
            AppLogger.shared.write(observation)
        }
        guard port != nil, let pressed = Self.physicalEdge(type: type, event: event, mode: mode) else { return }
        let observedAt = ProcessInfo.processInfo.systemUptime
        dispatchEdgeSafely(pressed: pressed, observedAt: observedAt, generation: generation, source: "cgevent_tap")
    }

    static func physicalEdge(type: CGEventType, event: CGEvent, mode: VoiceKeyMode) -> Bool? {
        guard type == .flagsChanged,
              event.getIntegerValueField(.keyboardEventKeycode) == Int64(mode.keyCode),
              event.getIntegerValueField(.eventSourceUserData) != KeyboardInjector.syntheticEventMarker else { return nil }
        return event.flags.contains(mode.eventFlags)
    }

    deinit { stop() }
}
