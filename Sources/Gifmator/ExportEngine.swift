import Combine
import Foundation

/// Runs the two-pass `palettegen` / `paletteuse` ffmpeg pipeline. State is
/// exposed via Combine subjects (no `@Published` / `ObservableObject`) so this
/// file compiles on Command Line Tools alone.
final class ExportEngine {
    let isExporting = CurrentValueSubject<Bool, Never>(false)
    let progress = CurrentValueSubject<Double, Never>(0.0)

    private var activeProcesses: [Process] = []
    private let processesLock = NSLock()

    struct Options {
        let inputURL: URL
        let outputURL: URL
        let start: Double
        let end: Double
        let width: Int
        let fps: Int
        let ffmpegPath: String

        var durationSeconds: Double { max(0.001, end - start) }
    }

    enum ExportError: Error {
        case ffmpegFailed(stderrTail: String)
        case outputMissing

        var userMessage: String {
            switch self {
            case .ffmpegFailed(let tail):
                let trimmed = tail.trimmingCharacters(in: .whitespacesAndNewlines)
                return "ffmpeg exited with an error.\n\n\(trimmed.isEmpty ? "(no stderr output)" : trimmed)"
            case .outputMissing:
                return "ffmpeg finished successfully, but no output file was written to the chosen path."
            }
        }
    }

    func cancel() {
        processesLock.withLock {
            for process in activeProcesses where process.isRunning {
                process.terminate()
            }
        }
    }

    func export(options: Options) async throws {
        guard !isExporting.value else { return }
        isExporting.send(true)
        progress.send(0)

        defer {
            isExporting.send(false)
            processesLock.withLock {
                activeProcesses.removeAll()
            }
        }

        let paletteURL = try makePaletteTempURL()
        defer {
            try? FileManager.default.removeItem(at: paletteURL.deletingLastPathComponent())
        }

        try await runPalettegen(options: options, paletteURL: paletteURL)
        try Task.checkCancellation()
        try await runPaletteuse(options: options, paletteURL: paletteURL)

        guard FileManager.default.fileExists(atPath: options.outputURL.path) else {
            throw ExportError.outputMissing
        }
    }

    private func runPalettegen(options: Options, paletteURL: URL) async throws {
        // Both passes get -ss/-to against the SAME trimmed range so the palette
        // is derived only from the frames that actually ship in the GIF (biased
        // palette = ugly colour choices on cut-away content).
        let args: [String] = [
            "-y",
            "-nostdin",
            "-hide_banner",
            "-loglevel", "info",
            "-ss", formattedSeconds(options.start),
            "-to", formattedSeconds(options.end),
            "-i", options.inputURL.path,
            // h=-2 keeps the computed height even — safe for every encoder we
            // might feed later, and prevents a palette biased by sub-pixel
            // rounding at odd heights.
            "-vf", "fps=\(options.fps),scale=w=\(options.width):h=-2:flags=lanczos,palettegen=stats_mode=diff",
            paletteURL.path
        ]
        try await runFFmpeg(options: options, args: args, progressRange: 0.0...0.35)
    }

    private func runPaletteuse(options: Options, paletteURL: URL) async throws {
        let filter = "fps=\(options.fps),scale=w=\(options.width):h=-2:flags=lanczos[x];" +
                     "[x][1:v]paletteuse=dither=sierra2_4a:diff_mode=rectangle"
        let args: [String] = [
            "-y",
            "-nostdin",
            "-hide_banner",
            "-loglevel", "info",
            "-ss", formattedSeconds(options.start),
            "-to", formattedSeconds(options.end),
            "-i", options.inputURL.path,
            "-i", paletteURL.path,
            "-lavfi", filter,
            "-loop", "0",
            options.outputURL.path
        ]
        try await runFFmpeg(options: options, args: args, progressRange: 0.35...1.0)
    }

    private func formattedSeconds(_ seconds: Double) -> String {
        String(format: "%.3f", max(0, seconds))
    }

    private func makePaletteTempURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gifmator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("palette.png")
    }

    private func runFFmpeg(options: Options,
                           args: [String],
                           progressRange: ClosedRange<Double>) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: options.ffmpegPath)
            process.arguments = args

            let errPipe = Pipe()
            process.standardError = errPipe
            process.standardOutput = Pipe()

            let tailBox = StderrTail(limit: 4000)

            errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty,
                      let chunk = String(data: data, encoding: .utf8) else { return }
                tailBox.append(chunk)
                if let fraction = Self.parseProgress(chunk: chunk,
                                                     duration: options.durationSeconds) {
                    let mapped = progressRange.lowerBound
                        + (progressRange.upperBound - progressRange.lowerBound) * fraction
                    guard let self else { return }
                    let current = self.progress.value
                    if mapped > current {
                        self.progress.send(mapped)
                    }
                }
            }

            process.terminationHandler = { [weak self] proc in
                errPipe.fileHandleForReading.readabilityHandler = nil
                guard let self else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.processesLock.withLock {
                    self.activeProcesses.removeAll { $0 === proc }
                }

                if proc.terminationStatus == 0 {
                    if self.progress.value < progressRange.upperBound {
                        self.progress.send(progressRange.upperBound)
                    }
                    continuation.resume(returning: ())
                } else if proc.terminationReason == .uncaughtSignal {
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuation.resume(throwing: ExportError.ffmpegFailed(stderrTail: tailBox.value))
                }
            }

            do {
                try process.run()
                processesLock.withLock {
                    activeProcesses.append(process)
                }
            } catch {
                errPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

    private static func parseProgress(chunk: String, duration: Double) -> Double? {
        guard duration > 0 else { return nil }
        var latest: Double?
        let lines = chunk.split(whereSeparator: { $0 == "\r" || $0 == "\n" })
        for line in lines {
            guard let timeRange = line.range(of: "time=") else { continue }
            let after = line[timeRange.upperBound...]
            let token = after.prefix { !$0.isWhitespace }
            guard let seconds = parseTimeToken(String(token)) else { continue }
            latest = min(1.0, seconds / duration)
        }
        return latest
    }

    private static func parseTimeToken(_ token: String) -> Double? {
        let parts = token.split(separator: ":")
        guard parts.count == 3,
              let h = Double(parts[0]),
              let m = Double(parts[1]),
              let s = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + s
    }
}

private final class StderrTail: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    private let limit: Int

    init(limit: Int) { self.limit = limit }

    func append(_ chunk: String) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(chunk)
        if buffer.count > limit {
            buffer = String(buffer.suffix(limit))
        }
    }

    var value: String {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }
}
