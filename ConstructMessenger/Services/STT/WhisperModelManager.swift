import Foundation
import Combine

#if canImport(WhisperKit)
import WhisperKit
#endif

// MARK: - Model definitions

public enum WhisperModel: String, CaseIterable, Identifiable {
    case tiny   = "tiny"
    case base   = "base"
    case small  = "small"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .tiny:  return "Tiny (~75 MB)"
        case .base:  return "Base (~145 MB)"
        case .small: return "Small (~466 MB)"
        }
    }

    var huggingFaceRepo: String {
        "argmaxinc/whisperkit-coreml"
    }

    var variantName: String {
        "openai_whisper-\(rawValue)"
    }
}

public enum WhisperModelState: Equatable {
    case notDownloaded
    case downloading(progress: Double)
    case downloaded
    case loading
    case ready
    case failed(String)
}

// MARK: - WhisperModelManager

/// Manages download, caching, and lifecycle of Whisper models.
/// Models are stored in Application Support/whisper-models/ — never bundled.
@MainActor
public final class WhisperModelManager: ObservableObject {

    public static let shared = WhisperModelManager()

    @Published public private(set) var modelStates: [WhisperModel: WhisperModelState] = {
        Dictionary(uniqueKeysWithValues: WhisperModel.allCases.map { ($0, .notDownloaded) })
    }()

    @Published public private(set) var activeModel: WhisperModel? = nil

    private let modelsDirectory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("whisper-models", isDirectory: true)
    }()

    private var downloadTasks: [WhisperModel: URLSessionDownloadTask] = [:]

    private init() {
        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        refreshStates()
    }

    // MARK: - Public API

    public func refreshStates() {
        for model in WhisperModel.allCases {
            if case .downloading = modelStates[model] { continue }
            if case .loading = modelStates[model] { continue }
            if case .ready = modelStates[model] { continue }
            let url = modelDirectory(for: model)
            modelStates[model] = FileManager.default.fileExists(atPath: url.path) ? .downloaded : .notDownloaded
        }
    }

    public func modelDirectory(for model: WhisperModel) -> URL {
        // Use path recorded at download time (most reliable across WhisperKit versions)
        if let stored = UserDefaults.standard.string(forKey: "whisper_model_path_\(model.rawValue)") {
            return URL(fileURLWithPath: stored)
        }
        // WhisperKit.download(variant:downloadBase:) creates: downloadBase/models/{org}/{repo}/{variant}/
        return modelsDirectory
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml")
            .appendingPathComponent(model.variantName, isDirectory: true)
    }

    public func isDownloaded(_ model: WhisperModel) -> Bool {
        if case .ready = modelStates[model] { return true }
        if case .downloaded = modelStates[model] { return true }
        // Verify a required model file exists — not just the directory (guards against partial downloads)
        let melSpec = modelDirectory(for: model).appendingPathComponent("MelSpectrogram.mlmodelc")
        return FileManager.default.fileExists(atPath: melSpec.path)
    }

    public var isAvailable: Bool {
        WhisperModel.allCases.contains { isDownloaded($0) }
    }

    public func downloadModel(_ model: WhisperModel) async {
        guard !isDownloaded(model) else { return }
        modelStates[model] = .downloading(progress: 0)

        #if canImport(WhisperKit)
        do {
            try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
            let modelURL = try await WhisperKit.download(
                variant: model.variantName,
                downloadBase: modelsDirectory
            )
            // Store actual download path so modelDirectory(for:) is always accurate
            UserDefaults.standard.set(modelURL.path, forKey: "whisper_model_path_\(model.rawValue)")
            modelStates[model] = .downloaded
        } catch {
            modelStates[model] = .failed(error.localizedDescription)
        }
        #else
        modelStates[model] = .failed("WhisperKit package not linked")
        #endif
    }

    public func deleteModel(_ model: WhisperModel) {
        let url = modelDirectory(for: model)
        try? FileManager.default.removeItem(at: url)
        UserDefaults.standard.removeObject(forKey: "whisper_model_path_\(model.rawValue)")
        modelStates[model] = .notDownloaded
        if activeModel == model {
            activeModel = nil
        }
    }

    public func totalSizeOnDisk() -> Int64 {
        var total: Int64 = 0
        for model in WhisperModel.allCases where isDownloaded(model) {
            let url = modelDirectory(for: model)
            if let size = directorySize(url) {
                total += size
            }
        }
        return total
    }

    // MARK: - Private helpers

    private func directorySize(_ url: URL) -> Int64? {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var size: Int64 = 0
        for case let fileURL as URL in enumerator {
            let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey])
            size += Int64(resourceValues?.fileSize ?? 0)
        }
        return size
    }
}
