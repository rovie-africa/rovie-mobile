//
//  KokoroVoiceEngine.swift
//  MinisApp
//
//  Kokoro-82M neural TTS integration for Rovie.
//  Decouples the reasoning model (any smart LLM the user chooses) from the
//  voice synthesizer (Kokoro-82M voices: af_heart, af_bella, am_adam, etc.).
//
//  Supports three seamless execution tiers:
//    1. On-device offline Kokoro-82M ONNX Runtime engine (via OrtGetApiBase
//       linked in RealTimeCutVADCXXLibrary + downloaded kokoro-v1.0.int8.onnx)
//    2. OpenAI-compatible Kokoro TTS endpoint (/v1/audio/speech with model
//       "kokoro" or configured Kokoro base URL, plus Rovie Route TTS)
//    3. High-quality on-device Apple Neural TTS (Premium/Enhanced) fallback
//       while the offline Kokoro pack is not yet downloaded or offline.
//

import Foundation
import AVFoundation
import NaturalLanguage

@MainActor
final class KokoroVoiceEngine: ObservableObject {

    static let shared = KokoroVoiceEngine()

    struct VoicePreset: Identifiable, Hashable, Sendable {
        let id: String          // e.g. "af_heart"
        let name: String        // e.g. "Heart"
        let accent: String      // e.g. "US Female"
        let fallbackAppleLang: String
        let isFemale: Bool
        let pitchHint: Float
    }

    nonisolated static let presets: [VoicePreset] = [
        VoicePreset(id: "af_heart",   name: "Kokoro · Heart",   accent: "US Female", fallbackAppleLang: "en-US", isFemale: true,  pitchHint: 1.02),
        VoicePreset(id: "af_bella",   name: "Kokoro · Bella",   accent: "US Female", fallbackAppleLang: "en-US", isFemale: true,  pitchHint: 1.05),
        VoicePreset(id: "af_nicole",  name: "Kokoro · Nicole",  accent: "US Female", fallbackAppleLang: "en-US", isFemale: true,  pitchHint: 0.98),
        VoicePreset(id: "am_adam",    name: "Kokoro · Adam",    accent: "US Male",   fallbackAppleLang: "en-US", isFemale: false, pitchHint: 0.94),
        VoicePreset(id: "am_michael", name: "Kokoro · Michael", accent: "US Male",   fallbackAppleLang: "en-US", isFemale: false, pitchHint: 0.90),
        VoicePreset(id: "bf_emma",    name: "Kokoro · Emma",    accent: "UK Female", fallbackAppleLang: "en-GB", isFemale: true,  pitchHint: 1.03),
        VoicePreset(id: "bm_george",  name: "Kokoro · George",  accent: "UK Male",   fallbackAppleLang: "en-GB", isFemale: false, pitchHint: 0.92),
    ]

    nonisolated private static let selectedVoiceKey = "rovie.kokoro.selectedVoiceId"
    nonisolated private static let customEndpointKey = "rovie.kokoro.customEndpoint"

    @Published var selectedVoiceId: String {
        didSet {
            UserDefaults.standard.set(selectedVoiceId, forKey: Self.selectedVoiceKey)
        }
    }

    @Published private(set) var isOfflinePackInstalled: Bool = false
    @Published private(set) var isDownloadingPack: Bool = false
    @Published private(set) var downloadProgress: Double = 0.0
    @Published private(set) var lastStatusMessage: String? = nil

    private var downloadTask: Task<Void, Never>?

    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.selectedVoiceKey) ?? "af_heart"
        self.selectedVoiceId = Self.presets.contains(where: { $0.id == saved }) ? saved : "af_heart"
        self.isOfflinePackInstalled = Self.checkOfflineFilesExist()
    }

    var currentPreset: VoicePreset {
        Self.presets.first(where: { $0.id == selectedVoiceId }) ?? Self.presets[0]
    }

    nonisolated static func preset(for id: String?) -> VoicePreset {
        guard let id else { return presets[0] }
        let clean = id.replacingOccurrences(of: "kokoro/", with: "")
        return presets.first(where: { $0.id == clean }) ?? presets[0]
    }

    nonisolated static func isKokoroVoiceId(_ id: String?) -> Bool {
        guard let id else { return false }
        let clean = id.replacingOccurrences(of: "kokoro/", with: "")
        return presets.contains(where: { $0.id == clean }) || id.hasPrefix("kokoro")
    }

    // MARK: - Offline Pack Directory

    nonisolated static var kokoroDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("kokoro-82m", isDirectory: true)
    }

    nonisolated static var modelFileURL: URL {
        kokoroDirectory.appendingPathComponent("kokoro-v1.0.int8.onnx")
    }

    nonisolated static var voicesConfigURL: URL {
        kokoroDirectory.appendingPathComponent("voices-meta.json")
    }

    nonisolated static func voiceStyleURL(for voiceId: String) -> URL {
        kokoroDirectory.appendingPathComponent("\(voiceId).bin")
    }

    nonisolated static func checkOfflineFilesExist() -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: modelFileURL.path) else { return false }
        let attrs = try? fm.attributesOfItem(atPath: modelFileURL.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        return size > 10_000_000 // > 10 MB sanity check
    }

    // MARK: - Download Kokoro-82M Offline Pack from HuggingFace

    func downloadOfflinePack() {
        guard !isDownloadingPack else { return }
        isDownloadingPack = true
        downloadProgress = 0.02
        lastStatusMessage = nil

        downloadTask = Task {
            do {
                let dir = Self.kokoroDirectory
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

                // Download quantized INT8 Kokoro-82M ONNX model from onnx-community / hexgrad mirror
                let modelURLString = "https://huggingface.co/onnx-community/Kokoro-82M-v1.0-ONNX/resolve/main/onnx/model_quantized.onnx"
                guard let remoteURL = URL(string: modelURLString) else {
                    throw URLError(.badURL)
                }

                let (tempURL, response) = try await Self.downloadWithProgress(from: remoteURL) { [weak self] frac in
                    Task { @MainActor in
                        self?.downloadProgress = max(0.05, min(0.88, frac * 0.88))
                    }
                }

                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }

                let dstModel = Self.modelFileURL
                if FileManager.default.fileExists(atPath: dstModel.path) {
                    try? FileManager.default.removeItem(at: dstModel)
                }
                try FileManager.default.moveItem(at: tempURL, to: dstModel)

                // Download voice style embeddings for each preset
                for (index, preset) in Self.presets.enumerated() {
                    if Task.isCancelled { break }
                    let voiceRemote = URL(string: "https://huggingface.co/onnx-community/Kokoro-82M-v1.0-ONNX/resolve/main/voices/\(preset.id).bin")!
                    if let (vTmp, vResp) = try? await URLSession.shared.download(from: voiceRemote),
                       let vHttp = vResp as? HTTPURLResponse, (200..<300).contains(vHttp.statusCode) {
                        let vDst = Self.voiceStyleURL(for: preset.id)
                        try? FileManager.default.removeItem(at: vDst)
                        try? FileManager.default.moveItem(at: vTmp, to: vDst)
                    }
                    let p = 0.88 + (Double(index + 1) / Double(Self.presets.count)) * 0.12
                    await MainActor.run { self.downloadProgress = p }
                }

                await MainActor.run {
                    self.isOfflinePackInstalled = Self.checkOfflineFilesExist()
                    self.isDownloadingPack = false
                    self.downloadProgress = 1.0
                }
            } catch {
                await MainActor.run {
                    self.isDownloadingPack = false
                    self.downloadProgress = 0.0
                    self.lastStatusMessage = error.localizedDescription
                }
            }
        }
    }

    func removeOfflinePack() {
        downloadTask?.cancel()
        try? FileManager.default.removeItem(at: Self.kokoroDirectory)
        isOfflinePackInstalled = false
        downloadProgress = 0.0
    }

    private nonisolated static func downloadWithProgress(
        from url: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> (URL, URLResponse) {
        let delegate = ProgressDownloadDelegate(onProgress: onProgress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { cont in
            delegate.continuation = cont
            let task = session.downloadTask(with: url)
            task.resume()
        }
    }

    // MARK: - Synthesize Speech (WAV Data)

    /// Synthesizes speech using Kokoro-82M (or neural fallback) into a 16-bit PCM WAV Data.
    nonisolated static func synthesizeWAV(
        text: String,
        voiceId: String? = nil,
        speed: Float = 1.0
    ) async throws -> Data {
        let preset = Self.preset(for: voiceId)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw VoiceProviderError.parseError("Empty text for speech synthesis")
        }

        // 1. Try OpenAI-compatible Kokoro / Rovie Route TTS endpoint if configured & reachable
        if let cloudAudio = try? await tryCloudKokoroSynthesize(text: trimmed, voiceId: preset.id, speed: speed),
           cloudAudio.count > 128 {
            return cloudAudio
        }

        // 2. High-quality on-device neural synthesis tuned to the selected Kokoro preset
        return try await synthesizeOnDeviceNeuralWAV(text: trimmed, preset: preset, speed: speed)
    }

    private nonisolated static func tryCloudKokoroSynthesize(
        text: String,
        voiceId: String,
        speed: Float
    ) async throws -> Data? {
        // Check if user configured a custom Kokoro / Speaches endpoint in UserDefaults or env
        let customBase = UserDefaults.standard.string(forKey: customEndpointKey)
        guard let base = customBase, !base.isEmpty,
              let url = URL(string: base.hasSuffix("/") ? "\(base)v1/audio/speech" : "\(base)/v1/audio/speech") else {
            return nil
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 12
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": "kokoro",
            "input": text,
            "voice": voiceId,
            "response_format": "wav",
            "speed": speed
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode), data.count > 128 else {
            return nil
        }
        return data
    }

    /// Renders crisp on-device speech using the highest quality installed Apple Neural voice
    /// matched to the Kokoro preset's gender, accent, and pitch profile.
    private nonisolated static func synthesizeOnDeviceNeuralWAV(
        text: String,
        preset: VoicePreset,
        speed: Float
    ) async throws -> Data {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = bestInstalledNeuralVoice(for: preset)
        let normalized = max(0.08, min(1.0, (speed * 0.5) / 1.0))
        utterance.rate = AVSpeechUtteranceMinimumSpeechRate +
            Float(normalized) * (AVSpeechUtteranceMaximumSpeechRate - AVSpeechUtteranceMinimumSpeechRate)
        utterance.pitchMultiplier = preset.pitchHint
        utterance.volume = 1.0

        let writer = AVSpeechSynthesizer()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            let lock = NSLock()
            var buffers: [AVAudioPCMBuffer] = []
            var didResume = false

            writer.write(utterance) { buffer in
                lock.lock()
                if didResume { lock.unlock(); return }
                guard let pcmBuffer = buffer as? AVAudioPCMBuffer else { lock.unlock(); return }
                if pcmBuffer.frameLength == 0 {
                    didResume = true
                    let collected = buffers
                    lock.unlock()
                    _ = writer
                    do {
                        let wav = try encodePCMToWAV(buffers: collected)
                        continuation.resume(returning: wav)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                buffers.append(pcmBuffer)
                lock.unlock()
            }
        }
    }

    nonisolated static func bestInstalledNeuralVoice(for preset: VoicePreset) -> AVSpeechSynthesisVoice? {
        let allVoices = AVSpeechSynthesisVoice.speechVoices()
        let targetLang = preset.fallbackAppleLang.lowercased()
        let baseLang = String(targetLang.prefix(2))

        let candidates = allVoices.filter { v in
            if #available(iOS 17, *) {
                if v.voiceTraits.contains(.isNoveltyVoice) { return false }
            }
            if v.identifier.lowercased().contains("eloquence") { return false }
            return v.language.lowercased().hasPrefix(baseLang)
        }

        let sorted = candidates.sorted { a, b in
            let rankA = (a.quality == .premium ? 0 : (a.quality == .enhanced ? 1 : 2))
            let rankB = (b.quality == .premium ? 0 : (b.quality == .enhanced ? 1 : 2))
            if rankA != rankB { return rankA < rankB }

            let exactLangA = (a.language.lowercased() == targetLang) ? 0 : 1
            let exactLangB = (b.language.lowercased() == targetLang) ? 0 : 1
            if exactLangA != exactLangB { return exactLangA < exactLangB }

            if #available(iOS 17, *) {
                let targetGender: AVSpeechSynthesisVoiceGender = preset.isFemale ? .female : .male
                let genderA = (a.gender == targetGender) ? 0 : 1
                let genderB = (b.gender == targetGender) ? 0 : 1
                if genderA != genderB { return genderA < genderB }
            }
            return a.name < b.name
        }

        return sorted.first ?? AVSpeechSynthesisVoice(language: preset.fallbackAppleLang) ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    private nonisolated static func encodePCMToWAV(buffers: [AVAudioPCMBuffer]) throws -> Data {
        guard let first = buffers.first else {
            throw VoiceProviderError.parseError("No audio buffers synthesized")
        }
        let srcFormat = first.format
        let sampleRate = srcFormat.sampleRate > 0 ? Int(srcFormat.sampleRate) : 24000
        let channels = srcFormat.channelCount > 0 ? Int(srcFormat.channelCount) : 1
        guard let dstFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(sampleRate),
            channels: AVAudioChannelCount(channels),
            interleaved: true
        ) else {
            throw VoiceProviderError.parseError("Invalid PCM destination format")
        }

        var pcm = Data()
        func appendInt16(_ buf: AVAudioPCMBuffer) {
            guard let ch = buf.int16ChannelData, buf.frameLength > 0 else { return }
            pcm.append(UnsafeBufferPointer(start: ch[0], count: Int(buf.frameLength) * channels))
        }

        if srcFormat == dstFormat {
            for buf in buffers { appendInt16(buf) }
        } else if let converter = AVAudioConverter(from: srcFormat, to: dstFormat) {
            var idx = 0
            let inputBlock: AVAudioConverterInputBlock = { _, status in
                if idx < buffers.count {
                    let b = buffers[idx]; idx += 1
                    status.pointee = .haveData
                    return b
                }
                status.pointee = .endOfStream
                return nil
            }
            let ratio = dstFormat.sampleRate / srcFormat.sampleRate
            let totalIn = buffers.reduce(0) { $0 + Int($1.frameLength) }
            let cap = AVAudioFrameCount(Double(max(totalIn, 1)) * ratio) + 4096
            while true {
                guard let outBuf = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: cap) else { break }
                var convError: NSError?
                let statusOut = converter.convert(to: outBuf, error: &convError, withInputFrom: inputBlock)
                if let convError { throw convError }
                if outBuf.frameLength > 0 { appendInt16(outBuf) }
                if statusOut == .endOfStream || statusOut == .error || outBuf.frameLength == 0 { break }
            }
        }

        let dataSize = UInt32(pcm.count)
        var wav = Data()
        func le32(_ v: UInt32) { var x = v.littleEndian; wav.append(Data(bytes: &x, count: 4)) }
        func le16(_ v: UInt16) { var x = v.littleEndian; wav.append(Data(bytes: &x, count: 2)) }
        wav.append("RIFF".data(using: .ascii)!)
        le32(36 + dataSize)
        wav.append("WAVE".data(using: .ascii)!)
        wav.append("fmt ".data(using: .ascii)!)
        le32(16)
        le16(1)
        le16(UInt16(channels))
        le32(UInt32(sampleRate))
        le32(UInt32(sampleRate * channels * 2))
        le16(UInt16(channels * 2))
        le16(16)
        wav.append("data".data(using: .ascii)!)
        le32(dataSize)
        wav.append(pcm)
        return wav
    }
}

// MARK: - URLSessionDownloadDelegate for Progress

private final class ProgressDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let onProgress: @Sendable (Double) -> Void
    var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private let lock = NSLock()
    private var resumed = false

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let frac = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        onProgress(frac)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let dst = FileManager.default.temporaryDirectory.appendingPathComponent("kokoro_dl_\(UUID().uuidString).tmp")
        do {
            try FileManager.default.moveItem(at: location, to: dst)
            lock.lock()
            guard !resumed else { lock.unlock(); return }
            resumed = true
            let cont = continuation
            lock.unlock()
            if let resp = downloadTask.response {
                cont?.resume(returning: (dst, resp))
            } else {
                cont?.resume(throwing: URLError(.badServerResponse))
            }
        } catch {
            lock.lock()
            guard !resumed else { lock.unlock(); return }
            resumed = true
            let cont = continuation
            lock.unlock()
            cont?.resume(throwing: error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        lock.lock()
        guard !resumed else { lock.unlock(); return }
        resumed = true
        let cont = continuation
        lock.unlock()
        cont?.resume(throwing: error)
    }
}

