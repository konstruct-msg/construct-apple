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

// MARK: - VoiceTranscriptionService

/// On-device voice message transcription via WhisperKit.
/// Audio never leaves the device after E2EE decryption.
@MainActor
public final class VoiceTranscriptionService {

    public static let shared = VoiceTranscriptionService()

    private let modelManager = WhisperModelManager.shared

    /// Preferred model for transcription. Falls back to any downloaded model.
    public var preferredModel: WhisperModel = .tiny

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
        let result = try await transcribeData(audioData)
        await MainActor.run {
            message.transcriptText = result.text
            message.transcriptLanguage = result.language
            message.transcriptGeneratedAt = Date()
            try? context.save()
        }
    }

    /// Returns true if a model is available to run transcription.
    public var isAvailable: Bool {
        WhisperModel.allCases.contains { modelManager.isDownloaded($0) }
    }

    // MARK: - Private transcription logic

    private func transcribeData(_ audioData: Data) async throws -> STTResult {
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
        // Default: auto-detect (nil). User can pin a source language for better accuracy.
        let storedLanguage = UserDefaults.standard.string(forKey: "stt_language") ?? "auto"
        let language: String? = (storedLanguage.isEmpty || storedLanguage == "auto") ? nil : storedLanguage
        // "Translate" mode always outputs English. Guard: if a non-English source language is
        // explicitly pinned, force transcribe — translating from a known non-English source is
        // only meaningful when the user really wants English output (toggle ON + language auto/en).
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

    private func resolveModel() -> WhisperModel? {
        if modelManager.isDownloaded(preferredModel) { return preferredModel }
        return WhisperModel.allCases.first { modelManager.isDownloaded($0) }
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
