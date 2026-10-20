import AVFoundation
import MemosCore
import Speech
import SwiftUI

/// Records a voice memo on the device while transcribing it live with on-device speech
/// recognition. When it stops, the instance's `AIService.Transcribe` gets a chance to do better;
/// without AI on the instance, or offline, the on-device transcript stands.
@Observable
final class VoiceRecorder {
    enum Phase: Equatable {
        case idle
        case recording
        case transcribing
        case finished
        case failed(String)
    }

    struct Recording {
        var file: URL
        var duration: TimeInterval
        var transcript: String
    }

    private(set) var phase: Phase = .idle
    /// Recent input levels, 0…1, newest last, for the waveform.
    private(set) var levels: [Float] = Array(repeating: 0, count: 40)
    private(set) var transcript = ""
    private(set) var startedAt: Date?
    /// The last finished recording, until a composer takes it.
    private(set) var lastRecording: Recording?

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var file: AVAudioFile?
    @ObservationIgnored private var fileURL: URL?
    @ObservationIgnored private var recognition: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var recognitionTask: SFSpeechRecognitionTask?

    var isRecording: Bool { phase == .recording }

    func start() async {
        guard phase != .recording else { return }
        guard await AVAudioApplication.requestRecordPermission() else {
            phase = .failed(String(localized: "Allow microphone access in Settings to record voice memos."))
            return
        }
        let speechAllowed = await Self.requestSpeechAuthorization()

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .spokenAudio)
            try session.setActive(true)

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            let url = FileManager.default.temporaryDirectory.appending(path: "Voice memo \(Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))).m4a".replacingOccurrences(of: ":", with: "-"))
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000,
            ]
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            self.file = file
            fileURL = url

            let recognizer = SFSpeechRecognizer()
            var request: SFSpeechAudioBufferRecognitionRequest?
            if speechAllowed, let recognizer, recognizer.isAvailable {
                let created = SFSpeechAudioBufferRecognitionRequest()
                created.shouldReportPartialResults = true
                created.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
                created.addsPunctuation = true
                request = created
                recognitionTask = recognizer.recognitionTask(with: created, resultHandler: Self.resultHandler { [weak self] text in
                    self?.transcript = text
                })
            }
            recognition = request

            input.installTap(onBus: 0, bufferSize: 2048, format: format, block: Self.tap(TapSink(file: file, request: request)) { [weak self] level in
                self?.push(level)
            })
            engine.prepare()
            try engine.start()
            transcript = ""
            startedAt = .now
            phase = .recording
        } catch {
            phase = .failed(String(localized: "Couldn’t start recording."))
        }
    }

    /// Stops recording and returns the audio with the best transcript available.
    func stop(client: MemosClient, online: Bool) async -> Recording? {
        guard phase == .recording, let fileURL else { return nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        recognition?.endAudio()
        file = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        let duration = startedAt.map { Date.now.timeIntervalSince($0) } ?? 0
        phase = .transcribing

        // Give on-device recognition a moment to deliver its final result.
        try? await Task.sleep(for: .milliseconds(400))
        recognitionTask?.finish()
        var text = transcript

        if online, let data = try? Data(contentsOf: fileURL) {
            var request = Memos_Api_TranscribeRequest()
            request.audio.content = data
            request.audio.filename = fileURL.lastPathComponent
            request.audio.contentType = "audio/mp4"
            if let response = try? await client.call(client.ai.transcribe(request:headers:), request),
               !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        transcript = text
        let recording = Recording(file: fileURL, duration: duration, transcript: text)
        lastRecording = recording
        phase = .finished
        return recording
    }

    func cancel() {
        guard phase == .recording else { phase = .idle; return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        recognitionTask?.cancel()
        file = nil
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        phase = .idle
    }

    func reset() {
        phase = .idle
        lastRecording = nil
        transcript = ""
        levels = Array(repeating: 0, count: levels.count)
    }

    private func push(_ level: Float) {
        levels.removeFirst()
        levels.append(level)
    }

    // The audio tap and the recognizer call back on their own queues, so their closures are
    // built here, away from the main actor, and hop back to it with what they found.

    /// What the audio tap writes into. Used only from the tap's queue once recording starts.
    private nonisolated final class TapSink: @unchecked Sendable {
        let file: AVAudioFile
        let request: SFSpeechAudioBufferRecognitionRequest?

        init(file: AVAudioFile, request: SFSpeechAudioBufferRecognitionRequest?) {
            self.file = file
            self.request = request
        }
    }

    private nonisolated static func tap(_ sink: TapSink, onLevel: @escaping @MainActor (Float) -> Void) -> AVAudioNodeTapBlock {
        { buffer, _ in
            try? sink.file.write(from: buffer)
            sink.request?.append(buffer)
            let level = level(of: buffer)
            Task { @MainActor in onLevel(level) }
        }
    }

    private nonisolated static func resultHandler(_ onText: @escaping @MainActor (String) -> Void) -> @Sendable (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        { result, _ in
            guard let text = result?.bestTranscription.formattedString else { return }
            Task { @MainActor in onText(text) }
        }
    }

    private nonisolated static func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
    }

    private nonisolated static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<count { sum += samples[index] * samples[index] }
        let rms = (sum / Float(count)).squareRoot()
        // Map roughly −50…0 dB onto 0…1.
        let decibels = 20 * log10(max(rms, 0.000_01))
        return max(0, min(1, (decibels + 50) / 50))
    }
}

/// The live waveform drawn while recording.
struct Waveform: View {
    let levels: [Float]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(.memosBlue)
                    .frame(width: 3, height: max(3, CGFloat(level) * 24))
            }
        }
        .animation(.linear(duration: 0.08), value: levels)
        .accessibilityHidden(true)
    }
}
