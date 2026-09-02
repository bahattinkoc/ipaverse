//
//  FridaDumper.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 2.09.2026.
//
//  Produces a DRM-free copy of an already-legitimately-installed App Store
//  IPA by reading the already-decrypted __TEXT bytes out of a *running*
//  instance of the app on a jailbroken device (same technique frida-ios-dump
//  uses), then patching those bytes into the on-disk binary and clearing its
//  FairPlay LC_ENCRYPTION_INFO flag. This does not break Apple's FairPlay
//  cryptography — it captures memory the OS already decrypted in order to
//  execute it. See Vendor/frida-core/README.md and the main README's
//  Security & Privacy section for the authorized-use framing.
//
//  Requires a jailbroken source device reachable over USB with frida-server
//  running, and the target app already open (so its code has actually been
//  paged in/decrypted — spawning suspended is not enough, since FairPlay
//  pages decrypt on first execution, not at map time).
//
//  libfrida-core is ~100MB, so it isn't linked into ipaverse.app — it's
//  downloaded on first use (FridaRuntime) and loaded with dlopen/dlsym. Every
//  frida_*/g_* symbol below is resolved at runtime through FridaCoreAPI
//  rather than called directly, so none of it is ever statically linked.
//  frida-core.h stays in the bridging header purely for its type/enum
//  declarations (GError, guint, FridaDeviceType, ...), which cost nothing at
//  link time since they're never referenced as callable symbols.

import Foundation

enum FridaDumperError: LocalizedError {
    case deviceManagerFailed(String)
    case noUSBDeviceFound
    case appNotRunning(String)
    case attachFailed(String)
    case scriptFailed(String)
    case dumpTimedOut
    case dumpMessageInvalid(String)
    case noEncryptedSegmentFound
    case segmentSizeMismatch(expected: Int, got: Int)
    case ipaStructureInvalid

    var errorDescription: String? {
        switch self {
        case .deviceManagerFailed(let msg): "Couldn't talk to Frida: \(msg)"
        case .noUSBDeviceFound: "No USB device found. Connect the jailbroken device and make sure frida-server is running on it."
        case .appNotRunning(let name): "\"\(name)\" doesn't seem to be running on the device. Open it and use it for a bit first, then try again."
        case .attachFailed(let msg): "Failed to attach to the app: \(msg)"
        case .scriptFailed(let msg): "Dump script failed: \(msg)"
        case .dumpTimedOut: "Timed out waiting for the dump. Make sure the app is in the foreground and try again."
        case .dumpMessageInvalid(let msg): "Unexpected response from the dump script: \(msg)"
        case .noEncryptedSegmentFound: "This binary has no FairPlay-encrypted segment (LC_ENCRYPTION_INFO) — it may already be DRM-free."
        case .segmentSizeMismatch(let expected, let got):
            "Dumped segment size (\(got) bytes) doesn't match the on-disk encrypted segment (\(expected) bytes)."
        case .ipaStructureInvalid: "Couldn't find a .app bundle inside this IPA."
        }
    }
}

// MARK: - Dynamically-resolved frida-core API

/// Every C entry point FridaDumper needs, resolved via dlsym from the
/// downloaded libfrida-core.dylib. Signatures mirror frida-core.h exactly.
private struct FridaCoreAPI {
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
    typealias Unref = @convention(c) (UnsafeMutableRawPointer?) -> Void
    typealias GErrorFree = @convention(c) (UnsafeMutablePointer<GError>?) -> Void
    typealias GSignalConnectData = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, GCallback?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UInt32) -> gulong
    typealias GBytesGetData = @convention(c) (OpaquePointer?, UnsafeMutablePointer<gsize>?) -> UnsafeRawPointer?

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
    let unrefRaw: Unref
    let gErrorFree: GErrorFree
    let gSignalConnectData: GSignalConnectData
    let gBytesGetData: GBytesGetData

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
        unrefRaw = try sym("frida_unref", as: Unref.self)
        gErrorFree = try sym("g_error_free", as: GErrorFree.self)
        gSignalConnectData = try sym("g_signal_connect_data", as: GSignalConnectData.self)
        gBytesGetData = try sym("g_bytes_get_data", as: GBytesGetData.self)
    }

    func unref(_ obj: OpaquePointer?) {
        guard let obj else { return }
        unrefRaw(UnsafeMutableRawPointer(obj))
    }
}

struct FridaDumper {

    // MARK: - Public entry point

    /// Dumps a decrypted copy of `ipaPath`'s main binary using a running
    /// instance of `appName` on a USB-connected jailbroken device, and writes
    /// a new, FairPlay-free IPA to `outputPath`.
    static func dumpDecrypted(
        ipaPath: String,
        appName: String,
        outputPath: String,
        progress: @escaping (String) -> Void
    ) throws {
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: workDir) }
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        progress("Opening IPA...")
        try runProcess(executable: "/usr/bin/unzip", arguments: ["-q", ipaPath, "-d", workDir.path])

        guard let appURL = try? FileManager.default.contentsOfDirectory(
            at: workDir.appendingPathComponent("Payload"), includingPropertiesForKeys: nil
        ).first(where: { $0.pathExtension == "app" }) else {
            throw FridaDumperError.ipaStructureInvalid
        }
        let executableName = appURL.deletingPathExtension().lastPathComponent
        let binaryURL = appURL.appendingPathComponent(executableName)

        let coreLibURL = try FridaRuntime.ensureCoreLibrary(progress: progress)
        let handle = try FridaRuntime.dlopenLibrary(at: coreLibURL)
        let api = try FridaCoreAPI(handle: handle)

        progress("Connecting to device...")
        let dump = try dumpFromDevice(api: api, processName: appName, progress: progress)

        progress("Patching binary...")
        try patch(binaryURL: binaryURL, cryptoff: dump.cryptoff, cryptsize: dump.cryptsize, decryptedBytes: dump.bytes)

        progress("Creating decrypted IPA...")
        try runProcess(
            executable: "/usr/bin/zip",
            workingDirectory: workDir,
            arguments: ["-qrX0", outputPath, "Payload"]
        )
    }

    // MARK: - Frida session

    private struct DumpResult {
        let cryptoff: Int
        let cryptsize: Int
        let bytes: Data
    }

    /// Bridges the async GObject "message" signal into a synchronous result:
    /// the C callback stashes the payload here and signals `semaphore`.
    fileprivate final class DumpContext {
        let semaphore = DispatchSemaphore(value: 0)
        let gBytesGetData: FridaCoreAPI.GBytesGetData
        var messageJSON: String?
        var messageData: Data?

        init(gBytesGetData: @escaping FridaCoreAPI.GBytesGetData) {
            self.gBytesGetData = gBytesGetData
        }
    }

    private static func dumpFromDevice(api: FridaCoreAPI, processName: String, progress: @escaping (String) -> Void) throws -> DumpResult {
        api.fridaInit()

        let manager = api.deviceManagerNew()
        defer {
            var closeError: UnsafeMutablePointer<GError>?
            api.deviceManagerCloseSync(manager, nil, &closeError)
            if let closeError { api.gErrorFree(closeError) }
            api.unref(manager)
        }

        var error: UnsafeMutablePointer<GError>?

        let deviceList = api.deviceManagerEnumerateDevicesSync(manager, nil, &error)
        if let error {
            defer { api.gErrorFree(error) }
            throw FridaDumperError.deviceManagerFailed(String(cString: error.pointee.message))
        }
        defer { api.unref(deviceList) }

        var usbDevice: OpaquePointer?
        let count = api.deviceListSize(deviceList)
        for i in 0..<count {
            let device = api.deviceListGet(deviceList, i)
            if api.deviceGetDtype(device) == FRIDA_DEVICE_TYPE_USB && usbDevice == nil {
                usbDevice = device // ownership transferred to usbDevice
            } else {
                api.unref(device)
            }
        }
        guard let device = usbDevice else { throw FridaDumperError.noUSBDeviceFound }
        defer { api.unref(device) }

        progress("Looking for \"\(processName)\" on the device...")
        let processes = api.deviceEnumerateProcessesSync(device, nil, nil, &error)
        if let error {
            defer { api.gErrorFree(error) }
            throw FridaDumperError.deviceManagerFailed(String(cString: error.pointee.message))
        }
        defer { api.unref(processes) }

        var targetPID: guint?
        let processCount = api.processListSize(processes)
        for i in 0..<processCount {
            let process = api.processListGet(processes, i)
            defer { api.unref(process) }
            guard let namePtr = api.processGetName(process) else { continue }
            let name = String(cString: namePtr)
            if name.localizedCaseInsensitiveContains(processName) {
                targetPID = api.processGetPid(process)
                break
            }
        }
        guard let pid = targetPID else { throw FridaDumperError.appNotRunning(processName) }

        progress("Attaching...")
        let session = api.deviceAttachSync(device, pid, nil, nil, &error)
        if let error {
            defer { api.gErrorFree(error) }
            throw FridaDumperError.attachFailed(String(cString: error.pointee.message))
        }
        defer {
            var detachError: UnsafeMutablePointer<GError>?
            api.sessionDetachSync(session, nil, &detachError)
            if let detachError { api.gErrorFree(detachError) }
            api.unref(session)
        }

        progress("Injecting dump agent...")
        let script = api.sessionCreateScriptSync(session, Self.dumpAgentSource, nil, nil, &error)
        if let error {
            defer { api.gErrorFree(error) }
            throw FridaDumperError.scriptFailed(String(cString: error.pointee.message))
        }
        defer { api.unref(script) }

        let context = DumpContext(gBytesGetData: api.gBytesGetData)
        let contextPtr = Unmanaged.passUnretained(context).toOpaque()
        // `fridaDumpMessageCallback` referenced directly is a "thick" Swift function
        // value (function pointer + context word); GCallback is a "thin" bare C
        // pointer. Casting straight to GCallback via unsafeBitCast trips a runtime
        // size-mismatch trap. Assigning to an explicitly @convention(c)-typed
        // constant first makes the compiler emit the thin form, which IS safely
        // bit-castable to GCallback (same size, just a different declared arity).
        let thinCallback: MessageCallback = fridaDumpMessageCallback
        _ = api.gSignalConnectData(
            UnsafeMutableRawPointer(script),
            "message",
            unsafeBitCast(thinCallback, to: GCallback.self),
            contextPtr,
            nil,
            0
        )

        api.scriptLoadSync(script, nil, &error)
        if let error {
            defer { api.gErrorFree(error) }
            throw FridaDumperError.scriptFailed(String(cString: error.pointee.message))
        }

        progress("Reading decrypted memory...")
        guard context.semaphore.wait(timeout: .now() + 30) == .success else {
            throw FridaDumperError.dumpTimedOut
        }

        guard let json = context.messageJSON,
              let jsonData = json.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        else {
            throw FridaDumperError.dumpMessageInvalid(context.messageJSON ?? "<empty>")
        }

        if let errorMessage = (payload["payload"] as? [String: Any])?["error"] as? String {
            throw FridaDumperError.dumpMessageInvalid(errorMessage)
        }
        guard let body = payload["payload"] as? [String: Any],
              let cryptoff = body["cryptoff"] as? Int,
              let cryptsize = body["cryptsize"] as? Int,
              let bytes = context.messageData
        else {
            throw FridaDumperError.dumpMessageInvalid(json)
        }

        return DumpResult(cryptoff: cryptoff, cryptsize: cryptsize, bytes: bytes)
    }

    /// Frida JS agent: locates the main image's LC_ENCRYPTION_INFO(_64) and
    /// reads the encrypted range directly out of live memory, where FairPlay
    /// has already decrypted it for execution. Sends the bytes back as the
    /// message's binary payload.
    private static let dumpAgentSource = """
    'use strict';
    function main() {
      const mod = Process.mainModule;
      const base = mod.base;
      const magic = base.readU32();
      const is64 = magic === 0xfeedfacf;
      if (!is64 && magic !== 0xfeedface) {
        send({ error: 'unsupported Mach-O magic' });
        return;
      }
      const ncmds = base.add(16).readU32();
      let offset = is64 ? 32 : 28;
      let found = null;
      for (let i = 0; i < ncmds; i++) {
        const cmd = base.add(offset).readU32();
        const cmdsize = base.add(offset + 4).readU32();
        if (cmd === 0x21 || cmd === 0x2c) {
          found = {
            cryptoff: base.add(offset + 8).readU32(),
            cryptsize: base.add(offset + 12).readU32(),
            cryptid: base.add(offset + 16).readU32(),
          };
          break;
        }
        offset += cmdsize;
      }
      if (found === null) {
        send({ error: 'no LC_ENCRYPTION_INFO found' });
        return;
      }
      if (found.cryptid === 0) {
        send({ error: 'already decrypted (cryptid=0)' });
        return;
      }
      const bytes = base.add(found.cryptoff).readByteArray(found.cryptsize);
      send({ cryptoff: found.cryptoff, cryptsize: found.cryptsize }, bytes);
    }
    main();
    """

    // MARK: - Binary patching

    private static func patch(binaryURL: URL, cryptoff: Int, cryptsize: Int, decryptedBytes: Data) throws {
        guard decryptedBytes.count == cryptsize else {
            throw FridaDumperError.segmentSizeMismatch(expected: cryptsize, got: decryptedBytes.count)
        }

        var data = try Data(contentsOf: binaryURL)
        func u32(_ offset: Int) -> UInt32 { data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt32.self) } }
        func setU32(_ offset: Int, _ value: UInt32) {
            withUnsafeBytes(of: value) { data.replaceSubrange(offset..<offset + 4, with: $0) }
        }

        let magic = u32(0)
        let is64 = magic == 0xFEED_FACF
        guard is64 || magic == 0xFEED_FACE else { throw FridaDumperError.noEncryptedSegmentFound }

        let ncmds = Int(u32(16))
        var cmdOffset = is64 ? 32 : 28
        var patchedCryptidOffset: Int?
        for _ in 0..<ncmds {
            let cmd = u32(cmdOffset)
            let cmdsize = Int(u32(cmdOffset + 4))
            if cmd == 0x21 || cmd == 0x2C {
                let onDiskOff = Int(u32(cmdOffset + 8))
                let onDiskSize = Int(u32(cmdOffset + 12))
                guard onDiskOff == cryptoff, onDiskSize == cryptsize else {
                    throw FridaDumperError.segmentSizeMismatch(expected: onDiskSize, got: cryptsize)
                }
                patchedCryptidOffset = cmdOffset + 16
                break
            }
            cmdOffset += cmdsize
        }
        guard let cryptidOffset = patchedCryptidOffset else { throw FridaDumperError.noEncryptedSegmentFound }

        data.replaceSubrange(cryptoff..<(cryptoff + cryptsize), with: decryptedBytes)
        setU32(cryptidOffset, 0)

        try data.write(to: binaryURL)
    }

    // MARK: - Process helper

    @discardableResult
    private static func runProcess(executable: String, workingDirectory: URL? = nil, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let wd = workingDirectory { process.currentDirectoryURL = wd }
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw FridaDumperError.dumpMessageInvalid(err.isEmpty ? out : err)
        }
        return out
    }
}

private typealias MessageCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, OpaquePointer?, UnsafeMutableRawPointer?) -> Void

/// Top-level C function pointer for the FridaScript "message" signal — Swift
/// closures can't be used as C callbacks since they can't capture context, so
/// state travels through `user_data` instead (see DumpContext above).
private func fridaDumpMessageCallback(
    _ script: UnsafeMutableRawPointer?,
    _ message: UnsafePointer<CChar>?,
    _ data: OpaquePointer?,
    _ userData: UnsafeMutableRawPointer?
) {
    guard let userData else { return }
    let context = Unmanaged<FridaDumper.DumpContext>.fromOpaque(userData).takeUnretainedValue()

    if let message {
        context.messageJSON = String(cString: message)
    }
    if let data {
        var size: gsize = 0
        if let ptr = context.gBytesGetData(data, &size), size > 0 {
            context.messageData = Data(bytes: ptr, count: Int(size))
        }
    }
    context.semaphore.signal()
}
