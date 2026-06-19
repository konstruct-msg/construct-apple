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

/// Manages download, caching, and lifecycle of Whisper models for on-device STT.
/// Models live in Application Support/whisper-models/ (survives updates).
/// reconcileModels() is called on init to recover models after app updates.
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
        reconcileModels()
    }

    // MARK: - Public API

    public func refreshStates() {
        reconcileModels()
    }

    /// Scans the models directory and recovers any models that physically exist on disk.
    /// This is the main defense against models "disappearing" after app updates,
    /// container migrations, or when stored absolute paths become stale.
    public func reconcileModels() {
        for model in WhisperModel.allCases {
            if case .downloading = modelStates[model] { continue }
            if case .loading = modelStates[model] { continue }
            if case .ready = modelStates[model] { continue }

            let canonical = canonicalDirectory(for: model)
            let canonicalCore = canonical.appendingPathComponent("MelSpectrogram.mlmodelc")
            var present = FileManager.default.fileExists(atPath: canonicalCore.path)

            // Legacy support: check old stored absolute path, clean it if stale.
            if let stored = UserDefaults.standard.string(forKey: "whisper_model_path_\(model.rawValue)") {
                let storedURL = URL(fileURLWithPath: stored)
                let storedCore = storedURL.appendingPathComponent("MelSpectrogram.mlmodelc")
                if FileManager.default.fileExists(atPath: storedCore.path) {
                    present = true
                } else {
                    UserDefaults.standard.removeObject(forKey: "whisper_model_path_\(model.rawValue)")
                    Log.info("Cleaned stale STT model path for \(model.rawValue)", category: "STT")
                }
            }

            let previous = modelStates[model]
            modelStates[model] = present ? .downloaded : .notDownloaded
            if present && previous != .downloaded {
                Log.info("Recovered STT model \(model.rawValue) after launch/update", category: "STT")
            }
        }
    }

    /// Always returns a deterministic location for this model inside our Application Support folder.
    /// We no longer rely on absolute paths returned by WhisperKit across app updates / container changes.
    private func canonicalDirectory(for model: WhisperModel) -> URL {
        modelsDirectory
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml")
            .appendingPathComponent(model.variantName, isDirectory: true)
    }

    public func modelDirectory(for model: WhisperModel) -> URL {
        // Legacy: if an old stored path still has the files, use it (will be cleaned on next reconcile).
        if let storedPath = UserDefaults.standard.string(forKey: "whisper_model_path_\(model.rawValue)") {
            let url = URL(fileURLWithPath: storedPath)
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("MelSpectrogram.mlmodelc").path) {
                return url
            }
        }
        return canonicalDirectory(for: model)
    }

    public func isDownloaded(_ model: WhisperModel) -> Bool {
        if case .ready = modelStates[model] { return true }
        if case .downloaded = modelStates[model] { return true }
        // Always check the canonical location (most reliable after updates).
        let melSpec = canonicalDirectory(for: model).appendingPathComponent("MelSpectrogram.mlmodelc")
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
            let _ = try await WhisperKit.download(
                variant: model.variantName,
                downloadBase: modelsDirectory
            )
            // Do not store absolute path. We rely on deterministic canonical location + reconcile.
            UserDefaults.standard.removeObject(forKey: "whisper_model_path_\(model.rawValue)")
            modelStates[model] = .downloaded
            Log.info("STT model \(model.rawValue) downloaded successfully to canonical location", category: "STT")
            // Re-scan to keep @Published state consistent (important if WhisperKit placed files in subdirs).
            reconcileModels()
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
