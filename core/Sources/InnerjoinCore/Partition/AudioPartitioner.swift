import Foundation
import AVFoundation
import Speech
import UniformTypeIdentifiers

/// Transcribes audio on-device with the Speech framework.
///
/// Each utterance becomes its own element, so a spoken fact can be cited the way a
/// paragraph is. There's no page geometry, so the timestamp takes the place of a
/// bounding box: `box` is nil and the element text carries `[mm:ss]`.
///
/// Video is deliberately not handled yet — the audio track alone would ignore
/// everything visual, which is usually the point of a video.
public struct AudioPartitioner: Partitioner {
    /// Utterances closer together than this are joined into one element, so a
    /// transcript reads in paragraphs rather than fragments.
    let joinGap: TimeInterval = 2.0
    /// Roughly a paragraph. Keeps elements citable rather than one wall of text.
    let maxElementCharacters = 700

    public init() {}

    public func handles(_ type: UTType) -> Bool {
        type.conforms(to: .audio) && !type.conforms(to: .movie)
    }

    public func partition(fileAt url: URL) async throws -> PartitionOutput {
        let locale = try await bestLocale()
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)

        // Speech models are downloaded on demand. Ask once; if the assets aren't
        // there and can't be fetched, say so plainly rather than failing obscurely.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file = try AVAudioFile(forReading: url)
        let duration = Double(file.length) / file.processingFormat.sampleRate

        // Collect results as they arrive while the file is fed in.
        let collector = Task { () -> [(start: TimeInterval, text: String)] in
            var pieces: [(TimeInterval, String)] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters).trimmed
                guard !text.isEmpty else { continue }
                pieces.append((result.range.start.seconds, text))
            }
            return pieces
        }

        do {
            _ = try await analyzer.analyzeSequence(from: file)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            collector.cancel()
            throw PartitionError.unreadable("This audio could not be transcribed: \(error.localizedDescription)")
        }

        let pieces = try await collector.value
        guard !pieces.isEmpty else {
            throw PartitionError.unreadable("No speech was found in this recording.")
        }

        return PartitionOutput(
            elements: group(pieces),
            pageCount: nil,
            warnings: ["Transcribed \(Self.clock(duration)) of audio."]
        )
    }

    /// Prefers the user's own language when a model exists for it, else US English.
    private func bestLocale() async throws -> Locale {
        let supported = await SpeechTranscriber.supportedLocales
        let current = Locale.current
        if supported.contains(where: { $0.identifier(.bcp47) == current.identifier(.bcp47) }) {
            return current
        }
        if let match = supported.first(where: {
            $0.language.languageCode == current.language.languageCode
        }) { return match }
        guard let fallback = supported.first(where: { $0.identifier(.bcp47).hasPrefix("en") })
                ?? supported.first else {
            throw PartitionError.unsupported("speech recognition (no language models installed)")
        }
        return fallback
    }

    /// Joins nearby utterances into paragraph-sized elements, each stamped with the
    /// time it starts — the transcript's equivalent of a page number.
    private func group(_ pieces: [(start: TimeInterval, text: String)]) -> [DraftElement] {
        var elements: [DraftElement] = []
        var buffer = ""
        var bufferStart = pieces.first?.start ?? 0
        var previousStart = bufferStart

        func flush() {
            let text = buffer.trimmed
            guard !text.isEmpty else { return }
            elements.append(DraftElement(.text, "[\(Self.clock(bufferStart))] \(text)"))
            buffer = ""
        }

        for piece in pieces {
            let farApart = piece.start - previousStart > joinGap
            if buffer.isEmpty {
                bufferStart = piece.start
            } else if farApart || buffer.count + piece.text.count > maxElementCharacters {
                flush()
                bufferStart = piece.start
            }
            buffer += buffer.isEmpty ? piece.text : " " + piece.text
            previousStart = piece.start
        }
        flush()
        return elements
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let (hours, minutes, secs) = (total / 3600, (total % 3600) / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}

