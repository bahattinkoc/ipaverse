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
//  FairPlay LC_ENCRYPTION_INFO flag. Does this for the main executable *and*
//  any bundled framework/dylib that carries its own LC_ENCRYPTION_INFO —
//  some SDKs (e.g. analytics/push frameworks) ship separately encrypted from
//  the main binary, and a resigned IPA that leaves one of those still
//  encrypted crashes at launch (dyld can't mmap it: "could not register
//  fairplay decryption, mremap_encrypted() => -1") before any app code runs.
//  This does not break Apple's FairPlay
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
        case .attachFailed(let msg): "Failed to attach to the app: \(msg)\(Self.antiFridaHint)"
        case .scriptFailed(let msg): "Dump script failed: \(msg)\(Self.antiFridaHint)"
        case .dumpTimedOut: "Timed out waiting for the dump. Make sure the app is in the foreground and try again.\(Self.antiFridaHint)"
        case .dumpMessageInvalid(let msg): "Unexpected response from the dump script: \(msg)"
        case .noEncryptedSegmentFound: "This binary has no FairPlay-encrypted segment (LC_ENCRYPTION_INFO) — it may already be DRM-free."
        case .segmentSizeMismatch(let expected, let got):
            "Dumped segment size (\(got) bytes) doesn't match the on-disk encrypted segment (\(expected) bytes)."
        case .ipaStructureInvalid: "Couldn't find a .app bundle inside this IPA."
        }
    }

    /// Appended to the failure modes a hardened app (banking apps especially)
    /// produces when it detects `frida-server` running on the device and
    /// voluntarily exits — not a crash (no crash report), just the app's own
    /// RASP code calling exit() the moment it sees Frida attach, typically by
    /// scanning the process list for the literal name "frida-server". Not
    /// something ipaverse can work around on its own: fixing it means hiding
    /// frida-server on the device itself (rename the binary and its
    /// LaunchDaemon, keep the same port — connecting over USB doesn't depend
    /// on the process name, so this doesn't break anything else that uses it).
    private static var antiFridaHint: String {
        " If the app closed right as this started, it may have detected " +
        "frida-server (many banking apps scan the process list for the name " +
        "\"frida-server\" and exit on sight) rather than crashed — check the " +
        "device's crash log: a clean/voluntary exit with no report points to " +
        "detection, not a bug. Renaming the frida-server binary and its " +
        "LaunchDaemon on the device (same port) usually fixes this."
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

    /// Dumps a decrypted copy of `ipaPath`'s main binary — and any bundled
    /// framework/dylib that's separately FairPlay-encrypted — using a running
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

        // Module name Frida sees for a loaded image is its own filename, which
        // for both the main executable and a framework's binary is the same as
        // the on-disk name we already have — no separate mapping needed.
        let candidates = [(name: executableName, url: binaryURL)] + embeddedBinaries(in: appURL)
        let encryptedTargets = candidates.filter { IPAResigner.isFairPlayEncrypted(binaryURL: $0.url) }
        guard !encryptedTargets.isEmpty else { throw FridaDumperError.noEncryptedSegmentFound }
        progress("Encrypted: \(encryptedTargets.map(\.name).joined(separator: ", "))")

        let coreLibURL = try FridaRuntime.ensureCoreLibrary(progress: progress)
        let handle = try FridaRuntime.dlopenLibrary(at: coreLibURL)
        let api = try FridaCoreAPI(handle: handle)

        progress("Connecting to device...")
        let dumps = try dumpFromDevice(
            api: api, processName: appName, moduleNames: encryptedTargets.map(\.name), progress: progress
        )

        for target in encryptedTargets {
            guard let dump = dumps[target.name] else {
                throw FridaDumperError.dumpMessageInvalid("no dump result for \(target.name)")
            }
            progress("Patching \(target.name)...")
            try patch(binaryURL: target.url, cryptoff: dump.cryptoff, cryptsize: dump.cryptsize, decryptedBytes: dump.bytes)
        }

        progress("Creating decrypted IPA...")
        try runProcess(
            executable: "/usr/bin/zip",
            workingDirectory: workDir,
            arguments: ["-qrX0", outputPath, "Payload"]
        )
    }

    // MARK: - Bundle scanning

    /// Every framework/dylib Mach-O binary loaded directly into the *main app
    /// process* — i.e. what's actually reachable via Process.getModuleByName
    /// while attached to the running app.
    ///
    /// Deliberately excludes PlugIns/*.appex: app extensions (share extensions,
    /// notification service extensions, widgets, ...) run as their own
    /// separate OS process, launched independently by the system when their
    /// extension point activates — they're never loaded into the containing
    /// app's process, so no amount of "use the app for a bit" makes them
    /// visible here. Dumping one requires attaching to *that* process while
    /// it's actually running (e.g. a live push notification for a
    /// NotificationServiceExtension), which is a separate, unimplemented flow.
    private static func embeddedBinaries(in appURL: URL) -> [(name: String, url: URL)] {
        let fm = FileManager.default
        var results: [(name: String, url: URL)] = []

        let frameworksDir = appURL.appendingPathComponent("Frameworks")
        guard let items = try? fm.contentsOfDirectory(at: frameworksDir, includingPropertiesForKeys: nil) else {
            return results
        }
        for item in items {
            if item.pathExtension == "framework" {
                let name = item.deletingPathExtension().lastPathComponent
                results.append((name, item.appendingPathComponent(name)))
            } else if item.pathExtension == "dylib" {
                results.append((item.lastPathComponent, item))
            }
        }
        return results
    }

    // MARK: - Frida session

    private struct DumpResult {
        let cryptoff: Int
        let cryptsize: Int
        let bytes: Data
    }

    /// Bridges the async GObject "message" signal into a synchronous result.
    /// The script can fire several "message" signals back-to-back (one per
    /// dumped module) before the Swift side gets around to consuming them, so
    /// each arrival is queued rather than stashed in a single shared slot —
    /// a single slot risks a later message overwriting an earlier one that
    /// hasn't been claimed by its matching semaphore.wait() yet.
    fileprivate final class DumpContext {
        let semaphore = DispatchSemaphore(value: 0)
        let gBytesGetData: FridaCoreAPI.GBytesGetData
        private let lock = NSLock()
        private var queue: [(json: String, data: Data?)] = []

        init(gBytesGetData: @escaping FridaCoreAPI.GBytesGetData) {
            self.gBytesGetData = gBytesGetData
        }

        func push(json: String, data: Data?) {
            lock.lock()
            queue.append((json, data))
            lock.unlock()
            semaphore.signal()
        }

        func pop() -> (json: String, data: Data?)? {
            lock.lock()
            defer { lock.unlock() }
            return queue.isEmpty ? nil : queue.removeFirst()
        }
    }

    private static func dumpFromDevice(
        api: FridaCoreAPI, processName: String, moduleNames: [String], progress: @escaping (String) -> Void
    ) throws -> [String: DumpResult] {
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
        let moduleNamesJSON = String(data: (try? JSONSerialization.data(withJSONObject: moduleNames)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
        let script = api.sessionCreateScriptSync(session, Self.dumpAgentSource(moduleNamesJSON: moduleNamesJSON), nil, nil, &error)
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

        var results: [String: DumpResult] = [:]
        for moduleName in moduleNames {
            progress("Reading decrypted memory (\(moduleName))...")
            guard context.semaphore.wait(timeout: .now() + 30) == .success else {
                throw FridaDumperError.dumpTimedOut
            }
            guard let (json, data) = context.pop() else {
                throw FridaDumperError.dumpMessageInvalid("<empty>")
            }

            guard let jsonData = json.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let body = payload["payload"] as? [String: Any],
                  let module = body["module"] as? String
            else {
                throw FridaDumperError.dumpMessageInvalid(json)
            }

            if let errorMessage = body["error"] as? String {
                throw FridaDumperError.dumpMessageInvalid("\(module): \(errorMessage)")
            }
            guard let cryptoff = body["cryptoff"] as? Int,
                  let cryptsize = body["cryptsize"] as? Int,
                  let bytes = data
            else {
                throw FridaDumperError.dumpMessageInvalid(json)
            }

            results[module] = DumpResult(cryptoff: cryptoff, cryptsize: cryptsize, bytes: bytes)
        }

        let missing = Set(moduleNames).subtracting(results.keys)
        guard missing.isEmpty else {
            throw FridaDumperError.dumpMessageInvalid("no dump result received for: \(missing.joined(separator: ", "))")
        }

        return results
    }

    /// Frida JS agent: for each named module, locates its LC_ENCRYPTION_INFO(_64)
    /// and reads the encrypted range directly out of live memory, where FairPlay
    /// has already decrypted it for execution. Sends one message per module
    /// back, in the same order, with the bytes as that message's binary payload.
    private static func dumpAgentSource(moduleNamesJSON: String) -> String {
    """
    'use strict';
    const __targets = \(moduleNamesJSON);
    function dumpModule(name) {
      let mod;
      try {
        mod = Process.getModuleByName(name);
      } catch (e) {
        send({ module: name, error: 'module not loaded: ' + e.message });
        return;
      }
      const base = mod.base;
      const magic = base.readU32();
      const is64 = magic === 0xfeedfacf;
      if (!is64 && magic !== 0xfeedface) {
        send({ module: name, error: 'unsupported Mach-O magic' });
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
        send({ module: name, error: 'no LC_ENCRYPTION_INFO found' });
        return;
      }
      if (found.cryptid === 0) {
        send({ module: name, error: 'already decrypted (cryptid=0)' });
        return;
      }
      const bytes = base.add(found.cryptoff).readByteArray(found.cryptsize);
      send({ module: name, cryptoff: found.cryptoff, cryptsize: found.cryptsize }, bytes);
    }
    __targets.forEach(dumpModule);
    """
    }

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
    guard let userData, let message else { return }
    let context = Unmanaged<FridaDumper.DumpContext>.fromOpaque(userData).takeUnretainedValue()

    var payloadData: Data?
    if let data {
        var size: gsize = 0
        if let ptr = context.gBytesGetData(data, &size), size > 0 {
            payloadData = Data(bytes: ptr, count: Int(size))
        }
    }
    context.push(json: String(cString: message), data: payloadData)
}
