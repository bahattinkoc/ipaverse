//
//  ClassicDeviceInstaller.swift
//  ipaverse
//
//  Created by BAHATTIN KOC on 2.09.2026.
//
//  Fallback device install path for iOS 16 and earlier. Apple's own
//  `xcrun devicectl` (Services/DeviceInstaller.swift) can list such devices
//  but can never install to them — its live tunnel requires RemoteXPC, a
//  service that only exists on iOS 17+. This reimplements the classic
//  usbmuxd -> lockdownd -> AFC -> installation_proxy stack (what
//  libimobiledevice, Sideloadly, and AltServer have used for years) via
//  dlopen/dlsym against the bundled libimobiledevice dylib chain
//  (Vendor/libimobiledevice/, ~6MB, bundled directly — see its README for
//  why this one isn't lazy-downloaded like Frida).

import Foundation

enum ClassicDeviceInstallerError: LocalizedError {
    case libraryLoadFailed(String)
    case noDevicesFound
    case connectFailed(String)
    case lockdownFailed(String)
    case serviceStartFailed(String)
    case uploadFailed(String)
    case installFailed(String)

    var errorDescription: String? {
        switch self {
        case .libraryLoadFailed(let msg): "Couldn't load the device communication library: \(msg)"
        case .noDevicesFound: "No paired devices found via usbmuxd."
        case .connectFailed(let msg): "Couldn't connect to the device: \(msg)"
        case .lockdownFailed(let msg): "Device handshake failed: \(msg)"
        case .serviceStartFailed(let msg): "Couldn't start a required service on the device: \(msg)"
        case .uploadFailed(let msg): "Failed to upload the app to the device: \(msg)"
        case .installFailed(let msg): "Installation failed: \(msg)"
        }
    }
}

// MARK: - Dynamically-resolved libimobiledevice API

private struct LibIMobileDeviceAPI {
    typealias IdeviceGetDeviceList = @convention(c) (UnsafeMutablePointer<UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?>?, UnsafeMutablePointer<Int32>?) -> Int32
    typealias IdeviceDeviceListFree = @convention(c) (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
    typealias IdeviceNew = @convention(c) (UnsafeMutablePointer<OpaquePointer?>?, UnsafePointer<CChar>?) -> Int32
    typealias IdeviceFree = @convention(c) (OpaquePointer?) -> Int32

    typealias LockdowndClientNewWithHandshake = @convention(c) (OpaquePointer?, UnsafeMutablePointer<OpaquePointer?>?, UnsafePointer<CChar>?) -> Int32
    typealias LockdowndClientFree = @convention(c) (OpaquePointer?) -> Int32
    typealias LockdowndGetValue = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafeMutablePointer<OpaquePointer?>?) -> Int32

    typealias InstproxyClientStartService = @convention(c) (OpaquePointer?, UnsafeMutablePointer<OpaquePointer?>?, UnsafePointer<CChar>?) -> Int32
    typealias InstproxyClientFree = @convention(c) (OpaquePointer?) -> Int32
    typealias InstproxyInstall = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, OpaquePointer?, InstproxyStatusCb?, UnsafeMutableRawPointer?) -> Int32
    typealias InstproxyStatusCb = @convention(c) (OpaquePointer?, OpaquePointer?, UnsafeMutableRawPointer?) -> Void
    typealias InstproxyStatusGetError = @convention(c) (OpaquePointer?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, UnsafeMutablePointer<UInt64>?) -> Int32
    typealias InstproxyStatusGetPercentComplete = @convention(c) (OpaquePointer?, UnsafeMutablePointer<Int32>?) -> Void

    typealias AfcClientStartService = @convention(c) (OpaquePointer?, UnsafeMutablePointer<OpaquePointer?>?, UnsafePointer<CChar>?) -> Int32
    typealias AfcClientFree = @convention(c) (OpaquePointer?) -> Int32
    typealias AfcMakeDirectory = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> Int32
    typealias AfcFileOpen = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, UInt32, UnsafeMutablePointer<UInt64>?) -> Int32
    typealias AfcFileWrite = @convention(c) (OpaquePointer?, UInt64, UnsafePointer<CChar>?, UInt32, UnsafeMutablePointer<UInt32>?) -> Int32
    typealias AfcFileClose = @convention(c) (OpaquePointer?, UInt64) -> Int32

    typealias PlistGetNodeType = @convention(c) (OpaquePointer?) -> Int32
    typealias PlistGetStringVal = @convention(c) (OpaquePointer?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Void
    typealias PlistFree = @convention(c) (OpaquePointer?) -> Void

    let ideviceGetDeviceList: IdeviceGetDeviceList
    let ideviceDeviceListFree: IdeviceDeviceListFree
    let ideviceNew: IdeviceNew
    let ideviceFree: IdeviceFree
    let lockdowndClientNewWithHandshake: LockdowndClientNewWithHandshake
    let lockdowndClientFree: LockdowndClientFree
    let lockdowndGetValue: LockdowndGetValue
    let instproxyClientStartService: InstproxyClientStartService
    let instproxyClientFree: InstproxyClientFree
    let instproxyInstall: InstproxyInstall
    let instproxyStatusGetError: InstproxyStatusGetError
    let instproxyStatusGetPercentComplete: InstproxyStatusGetPercentComplete
    let afcClientStartService: AfcClientStartService
    let afcClientFree: AfcClientFree
    let afcMakeDirectory: AfcMakeDirectory
    let afcFileOpen: AfcFileOpen
    let afcFileWrite: AfcFileWrite
    let afcFileClose: AfcFileClose
    let plistGetNodeType: PlistGetNodeType
    let plistGetStringVal: PlistGetStringVal
    let plistFree: PlistFree

    init(handle: UnsafeMutableRawPointer) throws {
        func sym<T>(_ name: String, as type: T.Type) throws -> T {
            unsafeBitCast(try FridaRuntime.dlsymRequired(handle, name), to: T.self)
        }
        ideviceGetDeviceList = try sym("idevice_get_device_list", as: IdeviceGetDeviceList.self)
        ideviceDeviceListFree = try sym("idevice_device_list_free", as: IdeviceDeviceListFree.self)
        ideviceNew = try sym("idevice_new", as: IdeviceNew.self)
        ideviceFree = try sym("idevice_free", as: IdeviceFree.self)
        lockdowndClientNewWithHandshake = try sym("lockdownd_client_new_with_handshake", as: LockdowndClientNewWithHandshake.self)
        lockdowndClientFree = try sym("lockdownd_client_free", as: LockdowndClientFree.self)
        lockdowndGetValue = try sym("lockdownd_get_value", as: LockdowndGetValue.self)
        instproxyClientStartService = try sym("instproxy_client_start_service", as: InstproxyClientStartService.self)
        instproxyClientFree = try sym("instproxy_client_free", as: InstproxyClientFree.self)
        instproxyInstall = try sym("instproxy_install", as: InstproxyInstall.self)
        instproxyStatusGetError = try sym("instproxy_status_get_error", as: InstproxyStatusGetError.self)
        instproxyStatusGetPercentComplete = try sym("instproxy_status_get_percent_complete", as: InstproxyStatusGetPercentComplete.self)
        afcClientStartService = try sym("afc_client_start_service", as: AfcClientStartService.self)
        afcClientFree = try sym("afc_client_free", as: AfcClientFree.self)
        afcMakeDirectory = try sym("afc_make_directory", as: AfcMakeDirectory.self)
        afcFileOpen = try sym("afc_file_open", as: AfcFileOpen.self)
        afcFileWrite = try sym("afc_file_write", as: AfcFileWrite.self)
        afcFileClose = try sym("afc_file_close", as: AfcFileClose.self)
        plistGetNodeType = try sym("plist_get_node_type", as: PlistGetNodeType.self)
        plistGetStringVal = try sym("plist_get_string_val", as: PlistGetStringVal.self)
        plistFree = try sym("plist_free", as: PlistFree.self)
    }
}

struct ClassicDeviceInstaller {

    private static let plistStringType: Int32 = 3 // PLIST_STRING, see libplist's plist.h `plist_type` enum
    private static let afcFopenWronly: UInt32 = 0x00000003 // AFC_FOPEN_WRONLY

    /// All 6 dylibs reference each other via `@loader_path/<plain-name>.dylib`
    /// (see Vendor/libimobiledevice/README.md), but they're bundled under
    /// `<plain-name>.dylib.bin` so Xcode doesn't try to link/embed them. Stage
    /// them together under their real names first so dyld's @loader_path
    /// resolution actually finds them — dlopen()ing the .bin path directly
    /// fails with "Library not loaded: @loader_path/libssl.3.dylib".
    private static let dylibNames = [
        "libimobiledevice-1.0.6.dylib",
        "libimobiledevice-glue-1.0.0.dylib",
        "libusbmuxd-2.0.7.dylib",
        "libplist-2.0.4.dylib",
        "libssl.3.dylib",
        "libcrypto.3.dylib",
    ]

    private static func loadAPI() throws -> LibIMobileDeviceAPI {
        let stagingDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ipaverse/LibIMobileDevice", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        for name in dylibNames {
            let dest = stagingDir.appendingPathComponent(name)
            guard !FileManager.default.fileExists(atPath: dest.path) else { continue }
            guard let resourceURL = Bundle.main.url(forResource: name, withExtension: "bin") else {
                print("⚙️ [ClassicDeviceInstaller] bundled resource not found: \(name).bin")
                throw ClassicDeviceInstallerError.libraryLoadFailed("Bundled resource not found: \(name).bin")
            }
            try FileManager.default.copyItem(at: resourceURL, to: dest)
        }

        let libURL = stagingDir.appendingPathComponent("libimobiledevice-1.0.6.dylib")
        do {
            let handle = try FridaRuntime.dlopenLibrary(at: libURL)
            let api = try LibIMobileDeviceAPI(handle: handle)
            print("⚙️ [ClassicDeviceInstaller] loaded \(libURL.lastPathComponent) OK")
            return api
        } catch {
            print("⚙️ [ClassicDeviceInstaller] loadAPI failed: \(error)")
            throw error
        }
    }

    // MARK: - List

    static func listDevices() throws -> [ConnectedDevice] {
        let api = try loadAPI()

        var rawList: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
        var count: Int32 = 0
        let rc = api.ideviceGetDeviceList(&rawList, &count)
        print("⚙️ [ClassicDeviceInstaller] idevice_get_device_list rc=\(rc) count=\(count)")
        guard rc == 0, let rawList, count > 0 else {
            return []
        }
        defer { _ = api.ideviceDeviceListFree(rawList) }

        var result: [ConnectedDevice] = []
        for i in 0..<Int(count) {
            guard let udidPtr = rawList[i] else { continue }
            let udid = String(cString: udidPtr)
            if let device = describeDevice(api: api, udid: udid) {
                result.append(device)
            } else {
                print("⚙️ [ClassicDeviceInstaller] describeDevice failed for udid=\(udid)")
            }
        }
        return result
    }

    private static func describeDevice(api: LibIMobileDeviceAPI, udid: String) -> ConnectedDevice? {
        var device: OpaquePointer?
        let newRc = api.ideviceNew(&device, udid)
        guard newRc == 0, let device else {
            print("⚙️ [ClassicDeviceInstaller] idevice_new rc=\(newRc) for \(udid)")
            return nil
        }
        defer { _ = api.ideviceFree(device) }

        var client: OpaquePointer?
        let lockdownRc = api.lockdowndClientNewWithHandshake(device, &client, "ipaverse")
        guard lockdownRc == 0, let client else {
            print("⚙️ [ClassicDeviceInstaller] lockdownd_client_new_with_handshake rc=\(lockdownRc) for \(udid)")
            return nil
        }
        defer { _ = api.lockdowndClientFree(client) }

        let name = getStringValue(api: api, client: client, key: "DeviceName") ?? "Unknown Device"
        let version = getStringValue(api: api, client: client, key: "ProductVersion") ?? ""
        let productType = getStringValue(api: api, client: client, key: "ProductType") ?? ""

        return ConnectedDevice(
            id: udid,
            name: name,
            model: productType,
            osVersion: version,
            platform: "iOS",
            isAvailable: true,
            transport: .wired,
            backend: .classic
        )
    }

    private static func getStringValue(api: LibIMobileDeviceAPI, client: OpaquePointer, key: String) -> String? {
        var node: OpaquePointer?
        guard api.lockdowndGetValue(client, nil, key, &node) == 0, let node else { return nil }
        defer { api.plistFree(node) }
        guard api.plistGetNodeType(node) == plistStringType else { return nil }
        var cString: UnsafeMutablePointer<CChar>?
        api.plistGetStringVal(node, &cString)
        guard let cString else { return nil }
        defer { free(cString) }
        return String(cString: cString)
    }

    // MARK: - Install

    fileprivate final class InstallContext {
        let api: LibIMobileDeviceAPI
        let progress: (String) -> Void
        var lastError: String?

        init(api: LibIMobileDeviceAPI, progress: @escaping (String) -> Void) {
            self.api = api
            self.progress = progress
        }
    }

    static func install(ipaPath: String, device: ConnectedDevice, progress: @escaping (String) -> Void) throws {
        let api = try loadAPI()

        var idevice: OpaquePointer?
        guard api.ideviceNew(&idevice, device.id) == 0, let idevice else {
            throw ClassicDeviceInstallerError.connectFailed("idevice_new failed for \(device.id)")
        }
        defer { _ = api.ideviceFree(idevice) }

        progress("Starting installation service...")
        var instClient: OpaquePointer?
        guard api.instproxyClientStartService(idevice, &instClient, "ipaverse") == 0, let instClient else {
            throw ClassicDeviceInstallerError.serviceStartFailed("installation_proxy")
        }
        defer { _ = api.instproxyClientFree(instClient) }

        progress("Starting file transfer service...")
        var afcClient: OpaquePointer?
        guard api.afcClientStartService(idevice, &afcClient, "ipaverse") == 0, let afcClient else {
            throw ClassicDeviceInstallerError.serviceStartFailed("afc")
        }
        defer { _ = api.afcClientFree(afcClient) }

        let remoteName = "ipaverse_\(UUID().uuidString).ipa"
        let remotePath = "PublicStaging/\(remoteName)"
        _ = api.afcMakeDirectory(afcClient, "PublicStaging") // ignore "already exists"

        progress("Uploading app...")
        try upload(api: api, afcClient: afcClient, localPath: ipaPath, remotePath: remotePath, progress: progress)

        progress("Installing on \(device.name)...")
        let context = InstallContext(api: api, progress: progress)
        let contextPtr = Unmanaged.passUnretained(context).toOpaque()
        let rc = api.instproxyInstall(instClient, remotePath, nil, installStatusCallback, contextPtr)

        // instproxy_install can return success at the protocol level (the
        // client/server message exchange completed cleanly) even though the
        // device's *last reported status* was a failure — e.g. installd's own
        // code-signature verification rejecting the app after the transfer
        // and protocol handshake already succeeded. Trust the last status
        // over the raw return code, since that's what actually reflects
        // whether the app is usable on the device (a bare rc==0 here can
        // silently leave the app as an unusable placeholder/"cloud" icon).
        guard rc == 0, context.lastError == nil else {
            throw ClassicDeviceInstallerError.installFailed(context.lastError ?? "installation_proxy error \(rc)")
        }

        progress("Installed on \(device.name)")
    }

    private static func upload(
        api: LibIMobileDeviceAPI,
        afcClient: OpaquePointer,
        localPath: String,
        remotePath: String,
        progress: @escaping (String) -> Void
    ) throws {
        guard let input = InputStream(fileAtPath: localPath) else {
            throw ClassicDeviceInstallerError.uploadFailed("Couldn't open \(localPath)")
        }
        let totalSize = (try? FileManager.default.attributesOfItem(atPath: localPath)[.size] as? Int) ?? nil

        var handle: UInt64 = 0
        guard api.afcFileOpen(afcClient, remotePath, afcFopenWronly, &handle) == 0 else {
            throw ClassicDeviceInstallerError.uploadFailed("afc_file_open failed for \(remotePath)")
        }
        defer { _ = api.afcFileClose(afcClient, handle) }

        input.open()
        defer { input.close() }

        let chunkSize = 256 * 1024
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var totalWritten = 0
        while input.hasBytesAvailable {
            let n = buffer.withUnsafeMutableBytes { input.read($0.baseAddress!, maxLength: chunkSize) }
            guard n > 0 else { break }

            var offset = 0
            while offset < n {
                var written: UInt32 = 0
                let rc = buffer.withUnsafeBytes { rawBuf -> Int32 in
                    let base = rawBuf.baseAddress!.advanced(by: offset).assumingMemoryBound(to: CChar.self)
                    return api.afcFileWrite(afcClient, handle, base, UInt32(n - offset), &written)
                }
                guard rc == 0, written > 0 else {
                    throw ClassicDeviceInstallerError.uploadFailed("afc_file_write failed (rc=\(rc))")
                }
                offset += Int(written)
            }
            totalWritten += n
            if let totalSize, totalSize > 0 {
                let pct = Int(Double(totalWritten) / Double(totalSize) * 100)
                progress("Uploading app... \(pct)%")
            }
        }
    }
}

/// `instproxy_install`'s status callback — invoked synchronously on the
/// calling thread while the install is in progress, not from another thread,
/// so no cross-thread synchronization is needed here (unlike FridaDumper's
/// GObject-signal-based callback).
private func installStatusCallback(
    command: OpaquePointer?,
    status: OpaquePointer?,
    userData: UnsafeMutableRawPointer?
) {
    guard let userData, let status else { return }
    let context = Unmanaged<ClassicDeviceInstaller.InstallContext>.fromOpaque(userData).takeUnretainedValue()

    var percent: Int32 = 0
    context.api.instproxyStatusGetPercentComplete(status, &percent)
    if percent > 0 {
        context.progress("Installing... \(percent)%")
    }

    var name: UnsafeMutablePointer<CChar>?
    var description: UnsafeMutablePointer<CChar>?
    var code: UInt64 = 0
    if context.api.instproxyStatusGetError(status, &name, &description, &code) == 0, name != nil || description != nil {
        let desc = description.map { String(cString: $0) } ?? name.map { String(cString: $0) } ?? "Unknown error"
        context.lastError = desc
    }
}
