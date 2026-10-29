// Copyright 2026 Slava Staroverov.
// Based on Jot by Ammaar Reshi (Apache License 2.0).
import Foundation

/// OpenAI-backed drop-in replacement for GeminiTranscriptionService.
///
/// The on-disk CAF is the sole durable recording. Jot's existing coordinator
/// owns recovery, history, dictation hotkey and safe insertion. We only replace
/// the transcription/cleanup transport here.
public struct OpenAITranscriptionService: TranscriptionServicing {
    private let client: OpenAIClient
    private let settings: SettingsStore
    public init(client: OpenAIClient, settings: SettingsStore = SettingsStore()) {
        self.client = client
        self.settings = settings
    }

    public func transcribe(audioURL: URL, durationSeconds: Double,
                           context: DictationContext) async throws -> TranscriptionResult {
        let config = settings.openAIConfig
        let flacURL = audioURL.deletingLastPathComponent().appendingPathComponent("audio.flac")
        let encoded = try FLACEncoder.encode(cafURL: audioURL, flacURL: flacURL)
        let flacData = try Data(contentsOf: encoded.url)
        try? FileManager.default.removeItem(at: encoded.url)
        let vocabulary = DictionaryStore().sanitizedVocabulary()
        let deadline = TimeoutPolicy.overallDeadline(audioDuration: durationSeconds)

        func request(_ terms: [String]) async throws -> String {
            try await client.transcribe(
                flacData: flacData,
                model: config.transcribeModel,
                vocabulary: terms,
                deadline: deadline,
                endpoint: config.endpoint
            )
        }

        func requestWithoutBadKeywords(_ terms: [String]) async throws -> String {
            do {
                return try await request(terms)
            } catch TranscriptionError.badRequest where !terms.isEmpty {
                // Bad vocabulary must never permanently block a dictation.
                return try await request([])
            }
        }

        func transcribeWithRetry(_ terms: [String]) async throws -> String {
            do {
                return try await requestWithoutBadKeywords(terms)
            } catch let error as TranscriptionError {
                switch error {
                case .network, .timeout, .rateLimitedTransient:
                    try await Task.sleep(nanoseconds: 500_000_000)
                    return try await requestWithoutBadKeywords(terms)
                default:
                    throw error
                }
            }
        }

        var raw = try await transcribeWithRetry(vocabulary)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty && durationSeconds >= 0.6 {
            raw = ((try? await requestWithoutBadKeywords(vocabulary)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !raw.isEmpty else { throw TranscriptionError.emptyTranscript }
        let replacements = DictionaryStore().replacementRules()
        let needsCleanup = settings.smartTranscriptionEnabled || settings.smartCleanupPassEnabled
        guard needsCleanup else {
            return TranscriptionResult(
                rawTranscript: raw,
                cleanedTranscript: ReplacementEngine.apply(replacements, to: raw),
                modelID: config.transcribeModel
            )
        }

        // Keep smart cleanup optional and fail-open. If the second model answers,
        // hallucinates or times out, never sacrifice the original words.
        let tone = settings.smartCleanupPassEnabled
            ? PromptV1.toneCategory(forBundleID: context.targetAppBundleID)
            : .neutral
        let prompt = PromptV1.cleanupPrompt(
            raw: raw, tone: tone, vocabulary: vocabulary,
            spellings: DictionaryStore().spellings()
        )
        do {
            let response = try await client.cleanup(
                prompt: prompt, model: config.cleanupModel,
                deadline: 7, endpoint: config.endpoint
            )
            let cleaned = ValidationGate.stripArtifacts(response)
            let verdict = ValidationGate.validate(raw: raw, cleaned: cleaned)
            guard verdict.accepted else {
                Log.transcription.warning("OpenAI cleanup rejected by validation gate — keeping transcript")
                return TranscriptionResult(
                    rawTranscript: raw,
                    cleanedTranscript: ReplacementEngine.apply(replacements, to: raw),
                    modelID: config.transcribeModel
                )
            }
            return TranscriptionResult(
                rawTranscript: raw,
                cleanedTranscript: ReplacementEngine.apply(replacements, to: cleaned),
                modelID: "\(config.transcribeModel)+\(config.cleanupModel)"
            )
        } catch {
            Log.transcription.info("OpenAI cleanup unavailable; original transcript retained")
            return TranscriptionResult(
                rawTranscript: raw,
                cleanedTranscript: ReplacementEngine.apply(replacements, to: raw),
                modelID: config.transcribeModel
            )
        }
    }
}
