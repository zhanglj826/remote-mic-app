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
    private var watchdogTimer: DispatchSourceTimer?
    private var tapLevel: TapLevel?
    private var generation: UInt64 = 0
    private var mode: VoiceKeyMode = .function
    private var lastDisabledLogAt: TimeInterval = 0
    private var lastObservedPressed = false
    private var nextTapHealthCheckAt: TimeInterval = 0

    @discardableResult
    func start(mode: VoiceKeyMode) -> Bool {
        lock.lock()
        let alreadyListening = port != nil && self.mode == mode
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

        // A voice tool such as Doubao may consume Fn in an earlier session tap.
        // Try the HID-level listen-only tap first so the physical edge remains
        // observable; fall back to the session-level head tap when unavailable.
        if let installed = installTap(level: .hid, mode: mode) {
            store(installed, level: .hid, mode: mode)
            return true
        }
        AppLogger.shared.write(
            "MAC MICROPHONE KEY_MONITOR phase=fallback result=session_head reason=hid_unavailable"
        )
        if let installed = installTap(level: .session, mode: mode) {
            store(installed, level: .session, mode: mode)
            return true
        }
        AppLogger.shared.write("MAC MICROPHONE KEY_MONITOR phase=failed reason=tap_unavailable")
        return false
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
        lastObservedPressed = Self.currentKeyState(mode: mode)
        nextTapHealthCheckAt = ProcessInfo.processInfo.systemUptime + 2
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.02, repeating: 0.02, leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in
            self?.pollKeyStateAndTapHealth()
        }
        watchdogTimer = timer
        lock.unlock()
        timer.resume()
        AppLogger.shared.write(
            "MAC MICROPHONE KEY_MONITOR phase=started result=listening " +
                "voice_key=\(mode.rawValue) event_passthrough=true tap=\(level.rawValue)"
        )
    }

    func stop() {
        lock.lock()
        let port = self.port
        let source = self.source
        let watchdogTimer = self.watchdogTimer
        let tapLevel = self.tapLevel?.rawValue ?? "unknown"
        self.port = nil
        self.source = nil
        self.watchdogTimer = nil
        self.tapLevel = nil
        self.lastObservedPressed = false
        generation &+= 1
        lock.unlock()
        watchdogTimer?.cancel()
        if port != nil || source != nil { EventTapPort.release(port: port, source: source) }
        if port != nil {
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
            let reason = type == .tapDisabledByTimeout ? "timeout" : "user_input"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.restoreTapIfDisabled(reason: reason)
            }
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
        deliverEdgeIfChanged(pressed, generation: generation, source: "event_tap")
    }

    static func physicalEdge(type: CGEventType, event: CGEvent, mode: VoiceKeyMode) -> Bool? {
        guard type == .flagsChanged,
              event.getIntegerValueField(.keyboardEventKeycode) == Int64(mode.keyCode),
              event.getIntegerValueField(.eventSourceUserData) != KeyboardInjector.syntheticEventMarker else { return nil }
        return event.flags.contains(mode.eventFlags)
    }

    static func currentKeyState(mode: VoiceKeyMode) -> Bool {
        CGEventSource.keyState(.hidSystemState, key: CGKeyCode(mode.keyCode))
    }

    private func pollKeyStateAndTapHealth() {
        lock.lock()
        guard port != nil else { lock.unlock(); return }
        let generation = self.generation
        let mode = self.mode
        let healthDue = ProcessInfo.processInfo.systemUptime >= nextTapHealthCheckAt
        if healthDue { nextTapHealthCheckAt = ProcessInfo.processInfo.systemUptime + 2 }
        lock.unlock()

        deliverEdgeIfChanged(Self.currentKeyState(mode: mode), generation: generation, source: "key_state_poll")
        if healthDue { restoreTapIfDisabled(reason: "watchdog") }
    }

    private func deliverEdgeIfChanged(_ pressed: Bool, generation: UInt64, source: String) {
        lock.lock()
        guard port != nil, self.generation == generation,
              pressed != lastObservedPressed else { lock.unlock(); return }
        lastObservedPressed = pressed
        lock.unlock()
        let observedAt = ProcessInfo.processInfo.systemUptime
        if source == "key_state_poll" {
            AppLogger.shared.write(
                "MAC MICROPHONE KEY_MONITOR phase=edge_recovered source=key_state_poll " +
                    "edge=\(pressed ? "down" : "up") voice_key=\(mode.rawValue)"
            )
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == generation else { return }
            self.onEdge(pressed, observedAt)
        }
    }

    /// Secure input and event-tap timeouts can leave a listen-only tap disabled even
    /// after an immediate re-enable attempt. Keep the original tap and retry enabling
    /// it after the protected input interval ends; rebuilding inside the callback can
    /// cause a disable/rebuild loop.
    private func restoreTapIfDisabled(reason: String) {
        lock.lock()
        guard let port else { lock.unlock(); return }
        let generation = self.generation
        let tapLevel = self.tapLevel?.rawValue ?? "unknown"
        lock.unlock()
        guard !CGEvent.tapIsEnabled(tap: port) else { return }

        CGEvent.tapEnable(tap: port, enable: true)
        let restored = CGEvent.tapIsEnabled(tap: port)
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let current = self.port === port && self.generation == generation
        let shouldLog = restored || now - lastDisabledLogAt >= 30
        if shouldLog { lastDisabledLogAt = now }
        lock.unlock()
        guard current, shouldLog else { return }
        AppLogger.shared.write(
            "MAC MICROPHONE KEY_MONITOR phase=recovery_attempt " +
                "result=\(restored ? "restored" : "still_disabled") " +
                "reason=\(reason) tap=\(tapLevel) rebuild=false"
        )
    }

    deinit { stop() }
}
