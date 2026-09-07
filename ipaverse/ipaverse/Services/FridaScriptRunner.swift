//
//  FridaScriptRunner.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 4.09.2026.
//
//  Attaches to an already-running app process on a USB-connected device
//  (jailbroken, or non-jailbroken with a Gadget injected via DylibInjector)
//  and loads an arbitrary Frida JS script, streaming every `send()` call
//  back as a live log line until the caller stops it.
//
//  This is a sibling to FridaDumper.swift, not a refactor of it: FridaDumper
//  is a proven, single-purpose flow (attach → run a fixed dump agent →
//  expect exactly N messages → detach) and touching its internals to make
//  them generic risks destabilizing a feature that already works. This file
//  duplicates the same dlsym/attach boilerplate for a genuinely different
//  shape: an open-ended session that stays attached, running whichever
//  script the Frida Toolkit UI picked, until the user hits Stop.
//
//  See FridaDumper.swift's header for why frida-core is dlopen'd at runtime
//  rather than linked, and the antiFridaHint on why some apps just exit the
//  moment frida-server/Gadget is detected.

import Foundation

enum FridaScriptRunnerError: LocalizedError {
    case deviceManagerFailed(String)
    case noUSBDeviceFound
    case appNotRunning(String)
    case ambiguousProcess(String, [String])
    case attachFailed(String)
    case scriptFailed(String)

    var errorDescription: String? {
        switch self {
        case .deviceManagerFailed(let msg): "Couldn't talk to Frida: \(msg)"
        case .noUSBDeviceFound: "No USB device found. Connect the device and make sure frida-server is running (or the app has a Gadget injected)."
        case .appNotRunning(let name): "\"\(name)\" doesn't seem to be running on the device. Open it first, then try again."
        case .ambiguousProcess(let name, let matches): "More than one running process matches \"\(name)\": \(matches.joined(separator: ", ")). Enter the exact process name."
        case .attachFailed(let msg): "Failed to attach: \(msg)"
        case .scriptFailed(let msg): "Script failed: \(msg)"
        }
    }
}

/// Same symbol subset as FridaDumper's private FridaCoreAPI, resolved
/// independently — see file header for why this isn't shared.
private struct FridaScriptAPI {
    typealias Init = @convention(c) () -> Void
    typealias DeviceManagerNew = @convention(c) () -> OpaquePointer?
    typealias DeviceManagerCloseSync = @convention(c) (OpaquePointer?, OpaquePointer?, UnsafeMutablePointer<UnsafeMutablePointer<GError>?>?) -> Void
    typealias DeviceManagerEnumerateDevicesSync = @convention(c) (OpaquePointer?, OpaquePointer?, UnsafeMutablePointer<UnsafeMutablePointer<GError>?>?) -> OpaquePointer?
    typealias DeviceListSize = @convention(c) (OpaquePointer?) -> gint
    typealias DeviceListGet = @convention(c) (OpaquePointer?, gint) -> OpaquePointer?
    typealias DeviceGetDtype = @convention(c) (OpaquePointer?) -> FridaDeviceType
    typealias DeviceEnumerateProcessesSync = @convention(c) (OpaquePointer?, OpaquePointer?, OpaquePointer?, UnsafeMutablePointer<UnsafeMutablePointer<GError>?>?) -> OpaquePointer?
    typealias ProcessListSize = @convention(c) (OpaquePointer?) -> gint
    typealias ProcessListGet = @convention(c) (OpaquePointer?, gint) -> OpaquePointer?
    typealias ProcessGetName = @convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?
    typealias ProcessGetPid = @convention(c) (OpaquePointer?) -> guint
    typealias DeviceAttachSync = @convention(c) (OpaquePointer?, guint, OpaquePointer?, OpaquePointer?, UnsafeMutablePointer<UnsafeMutablePointer<GError>?>?) -> OpaquePointer?
    typealias SessionDetachSync = @convention(c) (OpaquePointer?, OpaquePointer?, UnsafeMutablePointer<UnsafeMutablePointer<GError>?>?) -> Void
    typealias SessionCreateScriptSync = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, OpaquePointer?, OpaquePointer?, UnsafeMutablePointer<UnsafeMutablePointer<GError>?>?) -> OpaquePointer?
    typealias ScriptLoadSync = @convention(c) (OpaquePointer?, OpaquePointer?, UnsafeMutablePointer<UnsafeMutablePointer<GError>?>?) -> Void
    typealias ScriptUnloadSync = @convention(c) (OpaquePointer?, OpaquePointer?, UnsafeMutablePointer<UnsafeMutablePointer<GError>?>?) -> Void
    typealias ScriptPost = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, OpaquePointer?) -> Void
    typealias Unref = @convention(c) (UnsafeMutableRawPointer?) -> Void
    typealias GErrorFree = @convention(c) (UnsafeMutablePointer<GError>?) -> Void
    typealias GSignalConnectData = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, GCallback?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UInt32) -> gulong

    let fridaInit: Init
    let deviceManagerNew: DeviceManagerNew
    let deviceManagerCloseSync: DeviceManagerCloseSync
    let deviceManagerEnumerateDevicesSync: DeviceManagerEnumerateDevicesSync
    let deviceListSize: DeviceListSize
    let deviceListGet: DeviceListGet
    let deviceGetDtype: DeviceGetDtype
    let deviceEnumerateProcessesSync: DeviceEnumerateProcessesSync
    let processListSize: ProcessListSize
    let processListGet: ProcessListGet
    let processGetName: ProcessGetName
    let processGetPid: ProcessGetPid
    let deviceAttachSync: DeviceAttachSync
    let sessionDetachSync: SessionDetachSync
    let sessionCreateScriptSync: SessionCreateScriptSync
    let scriptLoadSync: ScriptLoadSync
    let scriptUnloadSync: ScriptUnloadSync
    let scriptPost: ScriptPost
    let unrefRaw: Unref
    let gErrorFree: GErrorFree
    let gSignalConnectData: GSignalConnectData

    init(handle: UnsafeMutableRawPointer) throws {
        func sym<T>(_ name: String, as type: T.Type) throws -> T {
            unsafeBitCast(try FridaRuntime.dlsymRequired(handle, name), to: T.self)
        }
        fridaInit = try sym("frida_init", as: Init.self)
        deviceManagerNew = try sym("frida_device_manager_new", as: DeviceManagerNew.self)
        deviceManagerCloseSync = try sym("frida_device_manager_close_sync", as: DeviceManagerCloseSync.self)
        deviceManagerEnumerateDevicesSync = try sym("frida_device_manager_enumerate_devices_sync", as: DeviceManagerEnumerateDevicesSync.self)
        deviceListSize = try sym("frida_device_list_size", as: DeviceListSize.self)
        deviceListGet = try sym("frida_device_list_get", as: DeviceListGet.self)
        deviceGetDtype = try sym("frida_device_get_dtype", as: DeviceGetDtype.self)
        deviceEnumerateProcessesSync = try sym("frida_device_enumerate_processes_sync", as: DeviceEnumerateProcessesSync.self)
        processListSize = try sym("frida_process_list_size", as: ProcessListSize.self)
        processListGet = try sym("frida_process_list_get", as: ProcessListGet.self)
        processGetName = try sym("frida_process_get_name", as: ProcessGetName.self)
        processGetPid = try sym("frida_process_get_pid", as: ProcessGetPid.self)
        deviceAttachSync = try sym("frida_device_attach_sync", as: DeviceAttachSync.self)
        sessionDetachSync = try sym("frida_session_detach_sync", as: SessionDetachSync.self)
        sessionCreateScriptSync = try sym("frida_session_create_script_sync", as: SessionCreateScriptSync.self)
        scriptLoadSync = try sym("frida_script_load_sync", as: ScriptLoadSync.self)
        scriptUnloadSync = try sym("frida_script_unload_sync", as: ScriptUnloadSync.self)
        scriptPost = try sym("frida_script_post", as: ScriptPost.self)
        unrefRaw = try sym("frida_unref", as: Unref.self)
        gErrorFree = try sym("g_error_free", as: GErrorFree.self)
        gSignalConnectData = try sym("g_signal_connect_data", as: GSignalConnectData.self)
    }

    func unref(_ obj: OpaquePointer?) {
        guard let obj else { return }
        unrefRaw(UnsafeMutableRawPointer(obj))
    }
}

/// Owns one live attach — device manager, device, session, script — and the
/// message callback's context. Runs entirely on a background thread (Frida's
/// own GLib main loop needs a thread that stays alive and pumping); `stop()`
/// unloads the script, detaches, and tears everything down.
final class FridaScriptHandle: @unchecked Sendable {
    fileprivate var api: FridaScriptAPI!
    fileprivate var manager: OpaquePointer?
    fileprivate var device: OpaquePointer?
    fileprivate var session: OpaquePointer?
    fileprivate var script: OpaquePointer?
    fileprivate let onMessage: (String) -> Void
    private var stopped = false
    private let lock = NSLock()

    fileprivate init(onMessage: @escaping (String) -> Void) {
        self.onMessage = onMessage
    }

    /// Sends a message into the running script — the host-to-script half of
    /// a `send()`/`recv()` conversation, used by network-request-logger's
    /// intercept mode to deliver an edited/forwarded request or toggle
    /// interception on/off. Verified empirically (local-spawn harness) that
    /// `frida_script_post` reaches a script blocked in `recv(type, cb).wait()`
    /// inside an `Interceptor.attach` callback and unblocks it correctly —
    /// also verified `stop()` below still returns in ~15ms even while a
    /// request is held pending (so Stop can never hang ipaverse itself),
    /// though the specific native thread stuck in that `recv().wait()` inside
    /// the *target* app has no guaranteed graceful unblock — Forward or Drop
    /// a pending request before hitting Stop where possible.
    func post(_ json: String) {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped, let script else { return }
        json.withCString { cstr in
            api.scriptPost(script, cstr, nil)
        }
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        stopped = true
        var error: UnsafeMutablePointer<GError>?
        if let script {
            api.scriptUnloadSync(script, nil, &error)
            if let error { api.gErrorFree(error) }
            error = nil
        }
        if let session {
            api.sessionDetachSync(session, nil, &error)
            if let error { api.gErrorFree(error) }
        }
        api.unref(script)
        api.unref(session)
        api.unref(device)
        var closeError: UnsafeMutablePointer<GError>?
        api.deviceManagerCloseSync(manager, nil, &closeError)
        if let closeError { api.gErrorFree(closeError) }
        api.unref(manager)
    }

    deinit { stop() }
}

enum FridaScriptRunner {

    /// Attaches to `processName` on a USB-connected device and loads
    /// `scriptSource`. The returned handle stays attached — call `stop()`
    /// (or let it deinit) to detach. Every `send()` call in the script
    /// arrives on `onMessage`, off the main thread; callers marshal to
    /// MainActor themselves.
    static func attachAndRun(
        processName: String,
        scriptSource: String,
        onMessage: @escaping (String) -> Void,
        progress: @escaping (String) -> Void
    ) throws -> FridaScriptHandle {
        let coreLibURL = try FridaRuntime.ensureCoreLibrary(progress: progress)
        let dlHandle = try FridaRuntime.dlopenLibrary(at: coreLibURL)
        let api = try FridaScriptAPI(handle: dlHandle)
        api.fridaInit()

        let handle = FridaScriptHandle(onMessage: onMessage)
        handle.api = api

        let manager = api.deviceManagerNew()
        handle.manager = manager

        var error: UnsafeMutablePointer<GError>?
        let deviceList = api.deviceManagerEnumerateDevicesSync(manager, nil, &error)
        if let error {
            defer { api.gErrorFree(error) }
            throw FridaScriptRunnerError.deviceManagerFailed(String(cString: error.pointee.message))
        }
        defer { api.unref(deviceList) }

        var usbDevice: OpaquePointer?
        let count = api.deviceListSize(deviceList)
        for i in 0..<count {
            let d = api.deviceListGet(deviceList, i)
            if api.deviceGetDtype(d) == FRIDA_DEVICE_TYPE_USB && usbDevice == nil {
                usbDevice = d
            } else {
                api.unref(d)
            }
        }
        guard let device = usbDevice else { throw FridaScriptRunnerError.noUSBDeviceFound }
        handle.device = device

        progress("Looking for \"\(processName)\"...")
        let processes = api.deviceEnumerateProcessesSync(device, nil, nil, &error)
        if let error {
            defer { api.gErrorFree(error) }
            throw FridaScriptRunnerError.deviceManagerFailed(String(cString: error.pointee.message))
        }
        defer { api.unref(processes) }

        var exactMatches: [(name: String, pid: guint)] = []
        var partialMatches: [(name: String, pid: guint)] = []
        let processCount = api.processListSize(processes)
        for i in 0..<processCount {
            let process = api.processListGet(processes, i)
            defer { api.unref(process) }
            guard let namePtr = api.processGetName(process) else { continue }
            let name = String(cString: namePtr)
            let candidate = (name: name, pid: api.processGetPid(process))
            if name.caseInsensitiveCompare(processName) == .orderedSame {
                exactMatches.append(candidate)
            } else if name.range(of: processName, options: [.caseInsensitive, .literal]) != nil {
                partialMatches.append(candidate)
            }
        }
        let matches = exactMatches.isEmpty ? partialMatches : exactMatches
        guard !matches.isEmpty else { throw FridaScriptRunnerError.appNotRunning(processName) }
        guard matches.count == 1 else {
            throw FridaScriptRunnerError.ambiguousProcess(processName, matches.map(\.name).sorted())
        }
        let pid = matches[0].pid

        progress("Attaching...")
        let session = api.deviceAttachSync(device, pid, nil, nil, &error)
        if let error {
            defer { api.gErrorFree(error) }
            throw FridaScriptRunnerError.attachFailed(String(cString: error.pointee.message))
        }
        handle.session = session

        progress("Loading script...")
        let script = api.sessionCreateScriptSync(session, scriptSource, nil, nil, &error)
        if let error {
            defer { api.gErrorFree(error) }
            throw FridaScriptRunnerError.scriptFailed(String(cString: error.pointee.message))
        }
        handle.script = script

        let contextPtr = Unmanaged.passUnretained(handle).toOpaque()
        let thinCallback: MessageCallback = fridaScriptMessageCallback
        _ = api.gSignalConnectData(
            UnsafeMutableRawPointer(script), "message",
            unsafeBitCast(thinCallback, to: GCallback.self),
            contextPtr, nil, 0
        )

        api.scriptLoadSync(script, nil, &error)
        if let error {
            defer { api.gErrorFree(error) }
            throw FridaScriptRunnerError.scriptFailed(String(cString: error.pointee.message))
        }

        progress("Running.")
        return handle
    }
}

private typealias MessageCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, OpaquePointer?, UnsafeMutableRawPointer?) -> Void

private func fridaScriptMessageCallback(
    _ script: UnsafeMutableRawPointer?,
    _ message: UnsafePointer<CChar>?,
    _ data: OpaquePointer?,
    _ userData: UnsafeMutableRawPointer?
) {
    guard let userData, let message else { return }
    let handle = Unmanaged<FridaScriptHandle>.fromOpaque(userData).takeUnretainedValue()
    handle.onMessage(String(cString: message))
}
