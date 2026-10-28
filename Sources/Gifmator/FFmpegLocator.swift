import Foundation

/// Finds the `ffmpeg` CLI on the user's machine.
///
/// First slice: look in the usual Homebrew / MacPorts / system install locations
/// and then walk the `PATH` environment variable. Bundling an LGPL ffmpeg binary
/// inside the `.app` is deferred to the shipping checklist (see feasibility plan).
struct FFmpegLocator {
    private let hardcodedCandidates: [String] = [
        "/opt/homebrew/bin/ffmpeg",   // Apple-silicon Homebrew default
        "/usr/local/bin/ffmpeg",      // Intel Homebrew / /usr/local installs
        "/usr/bin/ffmpeg",            // System default (rare on macOS)
        "/opt/local/bin/ffmpeg"       // MacPorts
    ]

    func locate() -> String? {
        for path in hardcodedCandidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return searchPathEnv()
    }

    private func searchPathEnv() -> String? {
        guard let pathEnv = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        for dir in pathEnv.split(separator: ":") {
            let candidate = String(dir) + "/ffmpeg"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
