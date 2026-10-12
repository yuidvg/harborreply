import AVFoundation
import Speech

/// Owns transient microphone resources. No file writer and no cloud fallback.
@MainActor final class LocalVoice {
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var token = UUID()
    private var tapInstalled = false
    private var stopping = false
    private var failed: ((String) -> Void)?
    private var timeout: Task<Void, Never>?

    func start(partial: @escaping (String) -> Void, finalized: @escaping (String, Bool) -> Void, failed: @escaping (String) -> Void) {
        cancel(); self.failed = failed; let token = self.token
        Task { [self] in
            let microphone = await AVCaptureDevice.requestAccess(for: .audio)
            let speech = await withCheckedContinuation { continuation in SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) } }
            guard self.token == token else { return }
            guard microphone, speech == .authorized else { failed("マイク・音声認識の権限がありません。テキスト入力を利用できます。"); return }
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP")), recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
                failed("端末内の日本語音声認識が利用できません。クラウドへは送らず、テキスト入力に戻ります。"); return
            }
            let request = SFSpeechAudioBufferRecognitionRequest(); request.requiresOnDeviceRecognition = true; request.shouldReportPartialResults = true
            self.request = request; self.stopping = false
            let node = engine.inputNode; let format = node.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { failed("音声入力デバイスが利用できません。"); return }
            node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
            tapInstalled = true
            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self, self.token == token else { return }
                    if let result {
                        if result.isFinal {
                            let stopped = self.stopping
                            self.stopAudio(); self.timeout?.cancel(); self.task = nil; self.request = nil
                            if stopped {
                                finalized(result.bestTranscription.formattedString, result.bestTranscription.segments.contains { $0.confidence < 0.85 })
                            } else { failed("録音が予期せず終了しました。文字起こしを確認してから生成してください。") }
                        } else { partial(result.bestTranscription.formattedString) }
                    } else if error != nil {
                        self.cancel(); failed("音声認識を完了できませんでした。テキスト入力を利用してください。")
                    }
                }
            }
            do { engine.prepare(); try engine.start() }
            catch { cancel(); failed("録音を開始できませんでした。テキスト入力を利用してください。") }
        }
    }
    func stop() {
        stopping = true; stopAudio(); request?.endAudio()
        timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }; let callback = self?.failed; self?.cancel(); callback?("確定結果を取得できませんでした。文字起こしを確認・修正してから生成してください。")
        }
    }
    private func stopAudio() {
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
    }
    func cancel() {
        token = UUID(); stopAudio(); request?.endAudio(); task?.cancel(); timeout?.cancel()
        request = nil; task = nil; stopping = false
    }
}
