import Foundation
import CoreData

#if canImport(WhisperKit)
import WhisperKit
#endif

// MARK: - Result type

public struct STTResult {
    public let text: String
    public let language: String?
    public let duration: TimeInterval
}

/// User-selectable transcription engine.
public enum TranscriptionEngine: String, CaseIterable {
    case auto
    case whisper
    case apple

    var displayName: String {
        switch self {
        case .auto: return NSLocalizedString("stt_engine_auto", comment: "")
        case .whisper: return NSLocalizedString("stt_engine_whisper", comment: "")
        case .apple: return NSLocalizedString("stt_engine_apple", comment: "")
        }
    }
}

// MARK: - VoiceTranscriptionService

/// On-device voice message transcription.
/// Audio never leaves the device after E2EE decryption.
/// Backed by WhisperKit (with fallback to system engines in future).
@MainActor
public final class VoiceTranscriptionService {

    public static let shared = VoiceTranscriptionService()

    fileprivate let modelManager = WhisperModelManager.shared

    /// Preferred model for transcription (used by Whisper backend). Falls back to any downloaded model.
    public var preferredModel: WhisperModel = .tiny

    // MARK: - Engine selection

    private var selectedEngine: TranscriptionEngine {
        let raw = UserDefaults.standard.string(forKey: "stt_engine") ?? "auto"
        return TranscriptionEngine(rawValue: raw) ?? .auto
    }

    /// Current active provider based on user preference + availability.
    private var provider: TranscriptionProvider {
        let engine = selectedEngine

        #if canImport(Speech) && canImport(AVFoundation)
        if #available(iOS 26, macOS 15, *) {
            let apple = AppleSpeechProvider()
            if apple.isAvailable && (engine == .apple || engine == .auto) {
                return apple
            }
        }
        #endif

        // Whisper or fallback
        if engine == .whisper || engine == .auto {
            return WhisperProvider(service: self)
        }

        // If Apple explicitly chosen but unavailable, fall back to Whisper
        return WhisperProvider(service: self)
    }

    private init() {}

    // MARK: - Public API

    /// Transcribes the given audio data and persists the result to CoreData.
    /// - Parameters:
    ///   - audioData: Raw audio bytes (m4a/opus/wav) from the decrypted voice message.
    ///   - message: The CoreData Message object to update with the transcript.
    ///   - context: The NSManagedObjectContext to save into.
    public func transcribe(
        audioData: Data,
        message: Message,
        context: NSManagedObjectContext
    ) async throws {
        let result = try await provider.transcribe(audioData: audioData)
        await MainActor.run {
            message.transcriptText = result.text
            message.transcriptLanguage = result.language
            message.transcriptGeneratedAt = Date()
            try? context.save()
        }
    }

    /// Returns true if a model/provider is available to run transcription.
    public var isAvailable: Bool {
        provider.isAvailable
    }

    // MARK: - Private helpers (Whisper-specific for now)

    private func resolveModel() -> WhisperModel? {
        // Respect user's choice from settings if that model is available.
        let preferredRaw = UserDefaults.standard.string(forKey: "stt_preferred_model") ?? WhisperModel.tiny.rawValue
        let chosen = WhisperModel(rawValue: preferredRaw) ?? .tiny
        if modelManager.isDownloaded(chosen) { return chosen }
        return WhisperModel.allCases.first { modelManager.isDownloaded($0) }
    }
}

// MARK: - Current (WhisperKit) implementation of the provider protocol

/// Thin adapter so the rest of the code talks to TranscriptionProvider instead of
/// concrete WhisperKit details. This is the starting point for multi-backend support.
private struct WhisperProvider: TranscriptionProvider {
    private weak var service: VoiceTranscriptionService?

    init(service: VoiceTranscriptionService) {
        self.service = service
    }

    var isAvailable: Bool {
        service?.modelManager.isAvailable ?? false
    }

    func transcribe(audioData: Data) async throws -> STTResult {
        guard let service else {
            throw TranscriptionError.engineUnavailable
        }
        return try await service.performWhisperTranscription(audioData: audioData)
    }
}

extension VoiceTranscriptionService {
    /// Extracted old transcribeData logic so the provider adapter can call it.
    /// (Temporary during the abstraction rollout — will be cleaned when Apple provider lands.)
    fileprivate func performWhisperTranscription(audioData: Data) async throws -> STTResult {
        #if canImport(WhisperKit)
        let model = resolveModel()
        guard let model else {
            throw TranscriptionError.noModelAvailable
        }

        let modelPath = modelManager.modelDirectory(for: model).path
        let whisper = try await WhisperKit(modelFolder: modelPath)

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".m4a")
        try audioData.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let translateEnabled = UserDefaults.standard.bool(forKey: "stt_translate")
        let storedLanguage = UserDefaults.standard.string(forKey: "stt_language") ?? "auto"
        let language: String? = (storedLanguage.isEmpty || storedLanguage == "auto") ? nil : storedLanguage

        let effectiveTranslate = translateEnabled && (language == nil || language == "en")
        let task: DecodingTask = effectiveTranslate ? .translate : .transcribe
        let options = DecodingOptions(task: task, language: language)

        let start = Date()
        let results = try await whisper.transcribe(audioPath: tempURL.path, decodeOptions: options)
        let duration = Date().timeIntervalSince(start)

        let text = results.map { $0.text }.joined(separator: " ").trimmingCharacters(in: CharacterSet.whitespaces)
        let lang = results.first?.language

        return STTResult(text: text, language: lang, duration: duration)
        #else
        throw TranscriptionError.engineUnavailable
        #endif
    }
}

// MARK: - Errors

public enum TranscriptionError: LocalizedError {
    case noModelAvailable
    case engineUnavailable

    public var errorDescription: String? {
        switch self {
        case .noModelAvailable:
            return NSLocalizedString("stt_error_no_model", comment: "")
        case .engineUnavailable:
            return NSLocalizedString("stt_error_unavailable", comment: "")
        }
    }
}
