import Foundation
import Darwin

enum ProcessRunner {
    struct Result { let output: Data; let error: Data }
    enum Failure: LocalizedError {
        case failed(String, Int32, String), timedOut(String), outputTooLarge
        var errorDescription: String? {
            switch self {
            case let .failed(name, status, detail): return "\(name) failed (\(status)): \(detail)"
            case .timedOut(let name): return "\(name) timed out."
            case .outputTooLarge: return "The tool produced too much output."
            }
        }
    }
    private final class Buffer: @unchecked Sendable {
        let lock = NSLock()
        var data = Data()
        var overflow = false
        func drain(_ handle: FileHandle, limit: Int) {
            while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                lock.lock()
                let remaining = max(0, limit - data.count)
                data.append(chunk.prefix(remaining))
                if chunk.count > remaining { overflow = true }
                lock.unlock()
            }
        }
    }

    static func run(_ executable: String, _ arguments: [String], directory: URL? = nil,
                    timeout: TimeInterval = 180, maxOutputBytes: Int = 16 * 1024 * 1024,
                    isCancelled: () -> Bool = { Task.isCancelled }) throws -> Result {
        if isCancelled() { throw CancellationError() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.useUTF8Locale()
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let out = Buffer(), err = Buffer(), group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            out.drain(stdout.fileHandleForReading, limit: maxOutputBytes)
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            err.drain(stderr.fileHandleForReading, limit: maxOutputBytes)
            group.leave()
        }
        let deadline = Date().addingTimeInterval(timeout)
        var interruption: Error?
        while process.isRunning {
            if isCancelled() { interruption = CancellationError() }
            else if Date() >= deadline { interruption = Failure.timedOut(URL(fileURLWithPath: executable).lastPathComponent) }
            if interruption != nil {
                process.terminate()
                let grace = Date().addingTimeInterval(1)
                while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.02) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        process.waitUntilExit()
        group.wait()
        if let interruption { throw interruption }
        if out.overflow || err.overflow { throw Failure.outputTooLarge }
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: err.data.isEmpty ? out.data : err.data, as: UTF8.self)
            throw Failure.failed(URL(fileURLWithPath: executable).lastPathComponent,
                                 process.terminationStatus, String(detail.prefix(2000)))
        }
        return Result(output: out.data, error: err.data)
    }
}
