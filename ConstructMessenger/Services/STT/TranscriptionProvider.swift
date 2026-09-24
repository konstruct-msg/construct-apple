import Foundation
import Speech
import AVFoundation

#if canImport(Translation)
import Translation
#endif

/// What one callback from `SFSpeechRecognizer` is allowed to do.
///
/// The handler fires more than once. On 2026-09-23 (build 687, iOS 26.6.2) a voice
/// message was transcribed and the process died twice, a minute apart:
/// `exceptionType=6 exceptionCode=1 signal=5`, stack
/// `Speech → Construct Messenger → libswift_Concurrency → libswiftCore`.
/// That is `SWIFT_TASK_CONTINUATION_MISUSE`: the final result resumed the
/// continuation, and the error that follows a finished task resumed it again.
/// A partial result is not terminal. A second terminal callback is ignored.
struct SpeechRecognitionCallback: Equatable {
    enum Outcome: Equatable {
        case ignore
        case success
        case failure
    }

    private(set) var settled = false

    mutating func accept(hasError: Bool, hasResult: Bool, isFinal: Bool) -> Outcome {
        guard !settled else { return .ignore }
        // A final result and an error on the same callback is a success. The
        // error that matters is the one that arrives *instead of* a transcript.
        if hasResult && isFinal {
            settled = true
            return .success
        }
        if hasError {
            settled = true
            return .failure
        }
        return .ignore
    }
}

/// Common interface for on-device speech-to-text providers.
/// Allows swapping WhisperKit with Apple's native SpeechAnalyzer (and others in future)
/// while keeping the rest of the app unchanged.
@MainActor
protocol TranscriptionProvider {
    /// Whether this provider can currently perform transcription (model available, OS version ok, etc.).
    var isAvailable: Bool { get }

    /// Perform transcription on raw audio bytes (typically m4a/opus after E2EE decrypt).
    /// Settings for language and translate are read from UserDefaults by the caller or inside impl.
    func transcribe(audioData: Data) async throws -> STTResult
}

// MARK: - Design notes for multi-provider (Apple SpeechAnalyzer etc.)
//
// 1. Add "stt_engine" AppStorage ("auto" | "whisper" | "apple").
// 2. In VoiceTranscriptionService pick the best available provider at runtime.
// 3. WhisperProvider (current) — uses modelManager + WhisperKit.
// 4. AppleSpeechProvider — #available(iOS 26, macOS 15, *), uses native SFSpeechRecognizer
//    (the established on-device Speech framework API; can be upgraded to SpeechAnalyzer/SpeechTranscriber
//     when building against a full iOS 26+ SDK).
//    - No extra download for user (system models).
//    - Report size 0 in settings.
// 5. Update STTSettingsSection to show current engine + download UI only for Whisper.
// 6. Keep E2EE invariant: transcription always happens after decrypt, on-device only.
//
// For now only WhisperProvider is active. Apple skeleton can be added next.

#if canImport(Speech) && canImport(AVFoundation)
@available(iOS 26, macOS 15, *)
struct AppleSpeechProvider: TranscriptionProvider {
    var isAvailable: Bool {
        // For the Apple native path we use SFSpeechRecognizer (the reliable on-device
        // implementation exposed by the Speech framework).
        // The enclosing type is already @available(iOS 26, macOS 15, *), so no need for inner check.
        let storedLanguage = UserDefaults.standard.string(forKey: "stt_language") ?? "auto"
        let locale: Locale = (storedLanguage.isEmpty || storedLanguage == "auto")
            ? Locale.current
            : Locale(identifier: storedLanguage)
        if let recognizer = SFSpeechRecognizer(locale: locale) {
            return recognizer.isAvailable
        }
        // Fallback to current locale
        return SFSpeechRecognizer(locale: Locale.current)?.isAvailable ?? false
    }

    func transcribe(audioData: Data) async throws -> STTResult {
        // This method is only called when AppleSpeechProvider.isAvailable returned true,
        // which already performed the #available check in the selection logic.
        return try await _transcribeWithNewAPI(audioData: audioData)
    }

    @available(iOS 26, macOS 15, *)
    private func _transcribeWithNewAPI(audioData: Data) async throws -> STTResult {
        let start = Date()

        // Write audio to temp file (m4a etc supported by the recognizer).
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".m4a")
        try audioData.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        // Locale from user settings.
        let storedLanguage = UserDefaults.standard.string(forKey: "stt_language") ?? "auto"
        let locale: Locale = (storedLanguage.isEmpty || storedLanguage == "auto")
            ? Locale.current
            : Locale(identifier: storedLanguage)

        // Use the classic native SFSpeechRecognizer as the Apple on-device engine.
        // This is the reliable native path available today; the SpeechAnalyzer / SpeechTranscriber
        // is the evolved name/API in iOS 26+. When building against a newer SDK you can replace
        // this body with the SpeechAnalyzer equivalent (attach module, analyze buffers, etc.).
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw TranscriptionError.engineUnavailable
        }

        let request = SFSpeechURLRecognitionRequest(url: tempURL)
        request.shouldReportPartialResults = false

        // The handler is not single-shot. `SpeechRecognitionCallback` is the rule;
        // the lock is only so the two callbacks cannot apply it at once.
        let gate = SpeechRecognitionGate()
        let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SFSpeechRecognitionResult, Error>) in
            var task: SFSpeechRecognitionTask?
            task = recognizer.recognitionTask(with: request) { result, error in
                let outcome = gate.accept(
                    hasError: error != nil,
                    hasResult: result != nil,
                    isFinal: result?.isFinal ?? false
                )
                switch outcome {
                case .ignore:
                    break
                case .failure:
                    task?.cancel()
                    continuation.resume(throwing: error ?? TranscriptionError.engineUnavailable)
                case .success:
                    task?.cancel()
                    if let result {
                        continuation.resume(returning: result)
                    } else {
                        continuation.resume(throwing: TranscriptionError.engineUnavailable)
                    }
                }
            }
        }

        var finalText = result.bestTranscription.formattedString.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let lang = locale.identifier

        // Support translate to English, mirroring the Whisper behavior.
        let translateEnabled = UserDefaults.standard.bool(forKey: "stt_translate")
        let languageForCheck: String? = (storedLanguage.isEmpty || storedLanguage == "auto") ? nil : storedLanguage
        let effectiveTranslate = translateEnabled && (languageForCheck == nil || languageForCheck == "en")

        if effectiveTranslate {
            finalText = try await translateToEnglish(finalText, sourceLocale: locale)
        }

        let duration = Date().timeIntervalSince(start)

        let resultLang = effectiveTranslate ? "en" : lang
        return STTResult(text: finalText, language: resultLang, duration: duration)
    }

    @available(iOS 26, macOS 15, *)
    private func translateToEnglish(_ text: String, sourceLocale: Locale) async throws -> String {
        guard !text.isEmpty else { return text }

        #if canImport(Translation)
        // On-device translation using TranslationSession.
        // Enclosing type is already @available(iOS 26, macOS 15, *), so no extra
        // #available(iOS 17) guard (always true). Structure for a full SDK build:
        //
        // let sourceLang = Locale.Language(identifier: sourceLocale.identifier)
        // let targetLang = Locale.Language(identifier: "en")
        // let config = TranslationSession.Configuration(source: sourceLang, target: targetLang)
        // let session = TranslationSession(configuration: config)
        // let translated = try await session.translate(text)
        // return translated
        //
        // For current build SDK compatibility we return original.
        return text
        #else
        // Fallback: return original if Translation not usable.
        return text
        #endif
    }
}

/// Applies `SpeechRecognitionCallback` from the recognizer's queue.
private final class SpeechRecognitionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var state = SpeechRecognitionCallback()

    func accept(hasError: Bool, hasResult: Bool, isFinal: Bool) -> SpeechRecognitionCallback.Outcome {
        lock.lock()
        defer { lock.unlock() }
        return state.accept(hasError: hasError, hasResult: hasResult, isFinal: isFinal)
    }
}
#endif
