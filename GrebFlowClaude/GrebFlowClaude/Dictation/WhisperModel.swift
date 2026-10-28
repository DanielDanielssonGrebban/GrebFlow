import Foundation
import os

/// The Whisper model GrebFlowClaude uses and where it lives on disk.
///
/// large-v3-turbo was the only model in our comparison that wrote JSON in
/// "parse the JSON response" and kept Jason in "ask Jason to review". The
/// small English model mixed them up.
enum WhisperModel {
    static let name = "openai_whisper-large-v3-v20240930_turbo_632MB"
    static let repo = "argmaxinc/whisperkit-coreml"
    /// WhisperKit finds the tokenizer when it sits next to the model files.
    static let tokenizerRepo = "openai/whisper-large-v3"
    static let tokenizerFiles = ["tokenizer.json", "tokenizer_config.json"]

    /// Files that must exist before the model counts as installed.
    static let requiredFiles = [
        "config.json",
        "AudioEncoder.mlmodelc",
        "TextDecoder.mlmodelc",
        "MelSpectrogram.mlmodelc",
        "tokenizer.json",
    ]

    static func baseDirectory() throws -> URL {
        try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("com.grebban.GrebFlowClaude", isDirectory: true)
            .appendingPathComponent("Whisper", isDirectory: true)
    }

    static func folder() throws -> URL {
        try baseDirectory().appendingPathComponent(name, isDirectory: true)
    }

    static func isInstalled(at folder: URL) -> Bool {
        requiredFiles.allSatisfy { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }
}

/// Downloads the Whisper model straight from Hugging Face. WhisperKit has
/// its own downloader, but it timed out on this network while plain
/// requests to the same host worked, so we fetch the files ourselves.
///
/// Files land in a `.partial` folder that is renamed when everything is
/// there, so an interrupted download never looks installed.
@MainActor
final class WhisperAssets: SpeechAssetProviding {
    private let logger = Logger(subsystem: "com.grebban.GrebFlowClaude", category: "whisper")

    var modelName: String { "Whisper model" }
    /// macOS compiles the model for the Neural Engine the first time this
    /// app loads it. That took about three minutes on an M-series Mac.
    var preparingMessage: String { "Preparing Whisper. The first time can take a few minutes." }

    func status() async -> SpeechAssetState {
        guard let folder = try? WhisperModel.folder() else { return .unknown }
        return WhisperModel.isInstalled(at: folder) ? .installed : .notInstalled
    }

    func install(progress: @escaping @MainActor @Sendable (Double) -> Void) async throws {
        let folder = try WhisperModel.folder()
        if WhisperModel.isInstalled(at: folder) { return }
        let partial = folder.appendingPathExtension("partial")
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)

        let files = try await Self.listFiles()
        let total = max(files.reduce(Int64(0)) { $0 + $1.size }, 1)
        var finished: Int64 = 0
        for file in files {
            let destination = partial.appendingPathComponent(file.relativePath)
            if let size = try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize, Int64(size) == file.size, file.size > 0 {
                finished += file.size
                progress(Double(finished) / Double(total))
                continue
            }
            let base = finished
            try await HTTPDownload.run(from: file.url, to: destination) { written in
                Task { @MainActor in progress(Double(base + written) / Double(total)) }
            }
            finished += file.size
        }

        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
        try FileManager.default.moveItem(at: partial, to: folder)
        guard WhisperModel.isInstalled(at: folder) else {
            throw WhisperModelError.incomplete
        }
        logger.info("Whisper model installed")
    }

    struct RemoteFile: Sendable {
        let relativePath: String
        let url: URL
        let size: Int64
    }

    private struct TreeEntry: Decodable {
        let type: String
        let path: String
        let size: Int64?
    }

    private static func listFiles() async throws -> [RemoteFile] {
        let modelEntries = try await tree(repo: WhisperModel.repo, folder: WhisperModel.name)
        let prefix = WhisperModel.name + "/"
        var files = modelEntries.map { entry in
            RemoteFile(
                relativePath: String(entry.path.dropFirst(prefix.count)),
                url: resolveURL(repo: WhisperModel.repo, path: entry.path),
                size: entry.size ?? 0
            )
        }
        let tokenizerEntries = try await tree(repo: WhisperModel.tokenizerRepo, folder: nil)
        for entry in tokenizerEntries where WhisperModel.tokenizerFiles.contains(entry.path) {
            files.append(RemoteFile(
                relativePath: entry.path,
                url: resolveURL(repo: WhisperModel.tokenizerRepo, path: entry.path),
                size: entry.size ?? 0
            ))
        }
        guard !files.isEmpty else { throw WhisperModelError.emptyListing }
        return files
    }

    private static func tree(repo: String, folder: String?) async throws -> [TreeEntry] {
        var path = "https://huggingface.co/api/models/\(repo)/tree/main"
        if let folder { path += "/\(folder)" }
        guard let url = URL(string: path + "?recursive=true") else { throw WhisperModelError.emptyListing }
        let (data, response) = try await URLSession.shared.data(from: url)
        try HTTPDownload.check(response)
        return try JSONDecoder().decode([TreeEntry].self, from: data).filter { $0.type == "file" }
    }

    private static func resolveURL(repo: String, path: String) -> URL {
        URL(string: "https://huggingface.co/\(repo)/resolve/main/\(path)")!
    }
}

enum WhisperModelError: LocalizedError {
    case emptyListing
    case incomplete
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .emptyListing: "Hugging Face didn't list any model files."
        case .incomplete: "Some model files are missing after the download."
        case let .httpStatus(code): "The server answered with HTTP \(code)."
        }
    }
}

/// One file download with byte progress, written to a temporary name and
/// moved into place when complete.
enum HTTPDownload {
    static func check(_ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw WhisperModelError.httpStatus(http.statusCode)
        }
    }

    static func run(from url: URL, to destination: URL, onBytes: @escaping @Sendable (Int64) -> Void) async throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let observation = ObservationBox()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // The temporary file is deleted when this handler returns, so it
            // has to be moved inside it.
            let task = URLSession.shared.downloadTask(with: url) { temporary, response, error in
                observation.invalidate()
                do {
                    if let error { throw error }
                    guard let temporary, let response else { throw WhisperModelError.incomplete }
                    try check(response)
                    if FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.removeItem(at: destination)
                    }
                    try FileManager.default.moveItem(at: temporary, to: destination)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            observation.set(task.progress.observe(\.completedUnitCount) { progress, _ in
                onBytes(progress.completedUnitCount)
            })
            task.resume()
        }
    }

    private final class ObservationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var observation: NSKeyValueObservation?

        func set(_ observation: NSKeyValueObservation) {
            lock.withLock { self.observation = observation }
        }

        func invalidate() {
            lock.withLock {
                observation?.invalidate()
                observation = nil
            }
        }
    }
}
