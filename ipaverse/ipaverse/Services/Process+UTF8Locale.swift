//
//  Process+UTF8Locale.swift
//  ipaverse
//

import Foundation

extension Process {
    /// macOS GUI apps are launched with no locale environment, so any CLI tool we
    /// spawn (unzip, zip, ditto, devicectl, codesign) defaults to the POSIX "C"
    /// locale. In that locale these tools transcode non-ASCII filenames to "?" —
    /// e.g. a UTF-8-flagged bundle name "Tıkla Gelsin.app" is listed/extracted as
    /// "T??kla Gelsin.app". That corrupts the bundle name (and, when baked into an
    /// injected SC_Info sinf path, the downloaded IPA itself), making installs
    /// fail with CoreDeviceError 3000/3002 ("not a valid bundle").
    ///
    /// Forcing a UTF-8 locale makes filename I/O round-trip correctly. Call this
    /// after setting `arguments` and before `run()`.
    func useUTF8Locale() {
        var env = environment ?? ProcessInfo.processInfo.environment
        env["LANG"] = "en_US.UTF-8"
        env["LC_ALL"] = "en_US.UTF-8"
        environment = env
    }
}
