import Foundation

/// Minimal process runner used to read the macOS keychain via `/usr/bin/security`.
///
/// Reading through the system `security` binary (rather than `SecItemCopyMatching`)
/// keeps the requesting identity as Apple's signed tool, which is already trusted by
/// the keychain item Claude Code created — so no ACL prompt is shown and no
/// partition list is stamped with this app's code signature.
///
/// stdout is drained on a background queue and stderr is discarded, so a child that
/// writes more than a pipe buffer to either stream cannot deadlock the caller. A
/// timeout bounds a hung child.
enum Shell {
    @discardableResult
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 5) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let finished = DispatchSemaphore(value: 0)
        var output = Data()
        DispatchQueue.global(qos: .utility).async {
            output = stdout.fileHandleForReading.readDataToEndOfFile()
            finished.signal()
        }

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return output
    }
}
