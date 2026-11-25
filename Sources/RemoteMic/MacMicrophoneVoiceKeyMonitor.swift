import AppKit
import CoreGraphics
import Foundation
import IOKit.hid

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

private func macMicrophoneHIDValueCallback(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    value: IOHIDValue
) {
    guard result == kIOReturnSuccess, let context else { return }
    Unmanaged<MacMicrophoneVoiceKeyMonitor>.fromOpaque(context)
        .takeUnretainedValue().observeHIDValue(value)
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
    private var hidManager: IOHIDManager?
    private var watchdogTimer: Timer?
    private var generation: UInt64 = 0
    private var mode: VoiceKeyMode = .function
    private var lastDispatchedEdge: (pressed: Bool, uptime: TimeInterval)?

    @discardableResult
    func start(mode: VoiceKeyMode) -> Bool {
        lock.lock()
        let alreadyListening = (port != nil || globalMonitor != nil || hidManager != nil) && self.mode == mode
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

        // 3. 底层 IOHIDManager 只读监听（位于 CGEventTap 之下，避免被其他 App 主动 tap 吞掉按下事件）
        installHIDMonitor(mode: mode)

        // 4. 启动看门狗定时器，每 3 秒检测底层 tap 状态
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

    private func installHIDMonitor(mode: VoiceKeyMode) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let currentGen = self.generation
            if let existing = self.hidManager {
                self.hidManager = nil
                self.lock.unlock()
                IOHIDManagerUnscheduleFromRunLoop(existing, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
                IOHIDManagerClose(existing, IOOptionBits(kIOHIDOptionsTypeNone))
            } else {
                self.lock.unlock()
            }

            let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
            let matching: [[String: Any]] = [
                [
                    kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
                    kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Keyboard,
                ],
                [
                    kIOHIDDeviceUsagePageKey as String: 0x00FF,
                    kIOHIDDeviceUsageKey as String: 0x0003,
                ],
            ]
            IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
            let context = Unmanaged.passUnretained(self).toOpaque()
            IOHIDManagerRegisterInputValueCallback(manager, macMicrophoneHIDValueCallback, context)
            IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            guard result == kIOReturnSuccess else {
                IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
                IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
                AppLogger.shared.write("MAC MICROPHONE KEY_MONITOR phase=failed reason=iohid_open_failed code=\(result)")
                return
            }

            self.lock.lock()
            let stillValid = self.generation == currentGen
            if stillValid {
                self.hidManager = manager
            }
            self.lock.unlock()

            if !stillValid {
                IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
                IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
                return
            }
            AppLogger.shared.write("MAC MICROPHONE KEY_MONITOR phase=iohid_monitor_started voice_key=\(mode.rawValue)")
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
        let hidManager = self.hidManager
        self.port = nil
        self.source = nil
        self.tapLevel = nil
        self.globalMonitor = nil
        self.localMonitor = nil
        self.hidManager = nil
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
            if let hidManager {
                IOHIDManagerUnscheduleFromRunLoop(hidManager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
                IOHIDManagerClose(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
            }
        }

        if port != nil || source != nil { EventTapPort.release(port: port, source: source) }
        if port != nil || globalMonitor != nil || localMonitor != nil || hidManager != nil {
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

    func observeHIDValue(_ value: IOHIDValue) {
        lock.lock()
        guard hidManager != nil else {
            lock.unlock()
            return
        }
        let generation = self.generation
        let mode = self.mode
        lock.unlock()

        let element = IOHIDValueGetElement(value)
        let usagePage = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let integerValue = IOHIDValueGetIntegerValue(value)
        guard let pressed = Self.hidEdge(
            usagePage: usagePage,
            usage: usage,
            integerValue: integerValue,
            mode: mode
        ) else { return }

        let observedAt = ProcessInfo.processInfo.systemUptime
        dispatchEdgeSafely(pressed: pressed, observedAt: observedAt, generation: generation, source: "iohid_manager")
    }

    static func hidEdge(usagePage: UInt32, usage: UInt32, integerValue: CFIndex, mode: VoiceKeyMode) -> Bool? {
        switch mode {
        case .function:
            guard usagePage == 0x00FF, usage == 0x0003 else { return nil }
            return integerValue != 0
        case .leftCommand:
            guard usagePage == UInt32(kHIDPage_KeyboardOrKeypad),
                  usage == UInt32(kHIDUsage_KeyboardLeftGUI) else { return nil }
            return integerValue != 0
        case .rightCommand:
            guard usagePage == UInt32(kHIDPage_KeyboardOrKeypad),
                  usage == UInt32(kHIDUsage_KeyboardRightGUI) else { return nil }
            return integerValue != 0
        case .leftOption:
            guard usagePage == UInt32(kHIDPage_KeyboardOrKeypad),
                  usage == UInt32(kHIDUsage_KeyboardLeftAlt) else { return nil }
            return integerValue != 0
        case .rightOption:
            guard usagePage == UInt32(kHIDPage_KeyboardOrKeypad),
                  usage == UInt32(kHIDUsage_KeyboardRightAlt) else { return nil }
            return integerValue != 0
        }
    }

    static func physicalEdge(type: CGEventType, event: CGEvent, mode: VoiceKeyMode) -> Bool? {
        guard type == .flagsChanged,
              event.getIntegerValueField(.keyboardEventKeycode) == Int64(mode.keyCode),
              event.getIntegerValueField(.eventSourceUserData) != KeyboardInjector.syntheticEventMarker else { return nil }
        return event.flags.contains(mode.eventFlags)
    }

    deinit { stop() }
}
