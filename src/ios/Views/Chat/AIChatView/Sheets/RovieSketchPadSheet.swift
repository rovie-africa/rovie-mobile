//
//  RovieSketchPadSheet.swift
//  MinisApp
//
//  Native PencilKit interactive sketch pad + Kokoro-82M synchronized voice tutor.
//  Any smart LLM chosen by the user acts as the brain (generating structured
//  visual steps + spoken explanations), PencilKit (PKCanvasView + PKStroke)
//  draws each step stroke-by-stroke, and Kokoro-82M narrates each step in sync.
//

import SwiftUI
import PencilKit
import AVFoundation
import UIKit

// MARK: - Data Models (Scene, Step, Element)

struct RovieSketchPoint: Codable, Hashable {
    let x: CGFloat
    let y: CGFloat

    init(x: CGFloat, y: CGFloat) {
        self.x = x
        self.y = y
    }

    init(from decoder: Decoder) throws {
        if var unkeyed = try? decoder.unkeyedContainer() {
            let px = (try? unkeyed.decode(CGFloat.self)) ?? 0
            let py = (try? unkeyed.decode(CGFloat.self)) ?? 0
            self.x = px
            self.y = py
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.x = (try? c.decode(CGFloat.self, forKey: .x)) ?? 0
        self.y = (try? c.decode(CGFloat.self, forKey: .y)) ?? 0
    }
}

struct RovieSketchElement: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var type: String                // box, rect, circle, ellipse, arrow, line, curve, path, highlight, underline, text
    var x: CGFloat?
    var y: CGFloat?
    var w: CGFloat?
    var h: CGFloat?
    var r: CGFloat?
    var x1: CGFloat?
    var y1: CGFloat?
    var x2: CGFloat?
    var y2: CGFloat?
    var points: [RovieSketchPoint]?
    var color: String?
    var label: String?
    var width: CGFloat?

    enum CodingKeys: String, CodingKey {
        case type, x, y, w, h, r, x1, y1, x2, y2, points, color, label, width
    }
}

struct RovieSketchStep: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var title: String?
    var speak: String?
    var elements: [RovieSketchElement]

    enum CodingKeys: String, CodingKey {
        case title, speak, elements
    }

    init(title: String? = nil, speak: String? = nil, elements: [RovieSketchElement] = []) {
        self.title = title
        self.speak = speak
        self.elements = elements
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.title = try? c.decode(String.self, forKey: .title)
        self.speak = try? c.decode(String.self, forKey: .speak)
        self.elements = (try? c.decode([RovieSketchElement].self, forKey: .elements)) ?? []
    }
}

struct RovieSketchScene: Codable, Equatable {
    var title: String?
    var voice: String?
    var steps: [RovieSketchStep]

    init(title: String? = nil, voice: String? = nil, steps: [RovieSketchStep] = []) {
        self.title = title
        self.voice = voice
        self.steps = steps
    }
}

// MARK: - Positioned Label Overlay

struct RovieSketchLabelOverlay: Identifiable, Equatable {
    let id: String
    let text: String
    let normalizedPosition: CGPoint // in 0...1000 space
    let colorHex: String
    let isHeading: Bool
}

// MARK: - PencilKit Stroke Builder (Converts Elements -> Real PKStroke Ink Paths)

enum RoviePKStrokeBuilder {

    static func parseColor(_ hex: String?, defaultColor: UIColor) -> UIColor {
        guard let hex = hex?.trimmingCharacters(in: .whitespacesAndNewlines), !hex.isEmpty else {
            return defaultColor
        }
        let named: [String: String] = [
            "blue": "#2563EB",
            "green": "#10B981",
            "purple": "#8B5CF6",
            "orange": "#F59E0B",
            "red": "#EF4444",
            "pink": "#EC4899",
            "teal": "#14B8A6",
            "cyan": "#06B6D4",
            "yellow": "#EAB308",
            "gray": "#6B7280",
            "black": "#1E293B",
            "white": "#F8FAFC"
        ]
        let resolvedHex = named[hex.lowercased()] ?? hex
        var cleaned = resolvedHex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        if cleaned.count == 3 {
            cleaned = cleaned.map { "\($0)\($0)" }.joined()
        }
        var int: UInt64 = 0
        guard Scanner(string: cleaned).scanHexInt64(&int) else { return defaultColor }
        let r = CGFloat((int >> 16) & 0xFF) / 255.0
        let g = CGFloat((int >> 8) & 0xFF) / 255.0
        let b = CGFloat(int & 0xFF) / 255.0
        return UIColor(red: r, green: g, blue: b, alpha: 1.0)
    }

    /// Maps normalized 0...1000 coordinates into the target canvas size with comfortable margins.
    static func mapPoint(_ nx: CGFloat, _ ny: CGFloat, in size: CGSize) -> CGPoint {
        let padX: CGFloat = 24
        let padY: CGFloat = 24
        let usableW = max(100, size.width - padX * 2)
        let usableH = max(100, size.height - padY * 2)
        let cx = padX + (nx / 1000.0) * usableW
        let cy = padY + (ny / 1000.0) * usableH
        return CGPoint(x: cx, y: cy)
    }

    /// Generates an array of PKStroke objects and optional label overlay for a single element.
    static func buildStrokes(
        for element: RovieSketchElement,
        in canvasSize: CGSize,
        isDarkCanvas: Bool
    ) -> (strokes: [PKStroke], label: RovieSketchLabelOverlay?) {
        let defaultColor = isDarkCanvas ? UIColor(red: 0.38, green: 0.65, blue: 0.98, alpha: 1.0)
                                        : UIColor(red: 0.15, green: 0.39, blue: 0.92, alpha: 1.0)
        let uiColor = parseColor(element.color, defaultColor: defaultColor)
        let baseWidth = element.width ?? 3.4
        let kind = element.type.lowercased()

        switch kind {
        case "box", "rect", "rectangle":
            let nx = element.x ?? 200
            let ny = element.y ?? 200
            let nw = element.w ?? 260
            let nh = element.h ?? 110
            let p1 = mapPoint(nx, ny, in: canvasSize)
            let p2 = mapPoint(nx + nw, ny, in: canvasSize)
            let p3 = mapPoint(nx + nw, ny + nh, in: canvasSize)
            let p4 = mapPoint(nx, ny + nh, in: canvasSize)

            let pathPoints = interpolatePolygon([p1, p2, p3, p4, p1], stepsPerEdge: 14, wobble: 0.9)
            let stroke = makeStroke(points: pathPoints, inkType: .pen, color: uiColor, width: baseWidth)
            let label = element.label.flatMap { text -> RovieSketchLabelOverlay? in
                guard !text.isEmpty else { return nil }
                return RovieSketchLabelOverlay(
                    id: element.id,
                    text: text,
                    normalizedPosition: CGPoint(x: nx + nw / 2, y: ny + nh / 2),
                    colorHex: element.color ?? "#2563EB",
                    isHeading: false
                )
            }
            return ([stroke], label)

        case "circle", "ellipse", "node":
            let nx = element.x ?? 500
            let ny = element.y ?? 400
            let nr = element.r ?? ((element.w ?? 140) / 2.0)
            let nw = element.w ?? (nr * 2)
            let nh = element.h ?? (nr * 2)
            let center = mapPoint(nx, ny, in: canvasSize)
            let edge = mapPoint(nx + nw / 2, ny + nh / 2, in: canvasSize)
            let rx = max(14, abs(edge.x - center.x))
            let ry = max(14, abs(edge.y - center.y))

            var pts: [CGPoint] = []
            let segments = 40
            for i in 0...segments {
                let angle = (CGFloat(i) / CGFloat(segments)) * (.pi * 2.0)
                let organic = 1.0 + sin(angle * 3.0) * 0.012
                let px = center.x + cos(angle) * rx * organic
                let py = center.y + sin(angle) * ry * organic
                pts.append(CGPoint(x: px, y: py))
            }
            let stroke = makeStroke(points: pts, inkType: .pen, color: uiColor, width: baseWidth)
            let label = element.label.flatMap { text -> RovieSketchLabelOverlay? in
                guard !text.isEmpty else { return nil }
                return RovieSketchLabelOverlay(
                    id: element.id,
                    text: text,
                    normalizedPosition: CGPoint(x: nx, y: ny),
                    colorHex: element.color ?? "#8B5CF6",
                    isHeading: false
                )
            }
            return ([stroke], label)

        case "arrow":
            let nx1 = element.x1 ?? element.x ?? 200
            let ny1 = element.y1 ?? element.y ?? 200
            let nx2 = element.x2 ?? (nx1 + (element.w ?? 200))
            let ny2 = element.y2 ?? (ny1 + (element.h ?? 0))
            let start = mapPoint(nx1, ny1, in: canvasSize)
            let end = mapPoint(nx2, ny2, in: canvasSize)

            let shaftPts = interpolateSegment(from: start, to: end, steps: 20, arcBow: 0.0)
            let shaft = makeStroke(points: shaftPts, inkType: .pen, color: uiColor, width: baseWidth)

            // Arrowhead wings
            let angle = atan2(end.y - start.y, end.x - start.x)
            let headLen: CGFloat = 13.0
            let wingAngle: CGFloat = .pi / 6.2
            let w1 = CGPoint(
                x: end.x - headLen * cos(angle - wingAngle),
                y: end.y - headLen * sin(angle - wingAngle)
            )
            let w2 = CGPoint(
                x: end.x - headLen * cos(angle + wingAngle),
                y: end.y - headLen * sin(angle + wingAngle)
            )
            let headPts = interpolatePolygon([w1, end, w2], stepsPerEdge: 6, wobble: 0.2)
            let head = makeStroke(points: headPts, inkType: .pen, color: uiColor, width: baseWidth)

            let label = element.label.flatMap { text -> RovieSketchLabelOverlay? in
                guard !text.isEmpty else { return nil }
                return RovieSketchLabelOverlay(
                    id: element.id,
                    text: text,
                    normalizedPosition: CGPoint(x: (nx1 + nx2) / 2, y: (ny1 + ny2) / 2 - 26),
                    colorHex: element.color ?? "#10B981",
                    isHeading: false
                )
            }
            return ([shaft, head], label)

        case "line", "underline", "highlight":
            let nx1 = element.x1 ?? element.x ?? 150
            let ny1 = element.y1 ?? element.y ?? 200
            let nx2 = element.x2 ?? (nx1 + (element.w ?? 240))
            let ny2 = element.y2 ?? ny1
            let start = mapPoint(nx1, ny1, in: canvasSize)
            let end = mapPoint(nx2, ny2, in: canvasSize)
            let isHighlight = (kind == "highlight")
            let ink: PKInk.InkType = isHighlight ? .marker : .pen
            let strokeColor = isHighlight ? uiColor.withAlphaComponent(0.35) : uiColor
            let strokeWidth = isHighlight ? max(baseWidth, 18.0) : baseWidth
            let pts = interpolateSegment(from: start, to: end, steps: 18, arcBow: 0.5)
            let stroke = makeStroke(points: pts, inkType: ink, color: strokeColor, width: strokeWidth)
            return ([stroke], nil)

        case "curve", "path", "stroke", "freehand":
            let rawPts = element.points ?? []
            guard rawPts.count >= 2 else { return ([], nil) }
            let mapped = rawPts.map { mapPoint($0.x, $0.y, in: canvasSize) }
            let dense = interpolatePolygon(mapped, stepsPerEdge: 12, wobble: 0.4)
            let stroke = makeStroke(points: dense, inkType: .pen, color: uiColor, width: baseWidth)
            let mid = rawPts[rawPts.count / 2]
            let label = element.label.flatMap { text -> RovieSketchLabelOverlay? in
                guard !text.isEmpty else { return nil }
                return RovieSketchLabelOverlay(
                    id: element.id,
                    text: text,
                    normalizedPosition: CGPoint(x: mid.x, y: mid.y - 24),
                    colorHex: element.color ?? "#EC4899",
                    isHeading: false
                )
            }
            return ([stroke], label)

        case "text", "label", "formula", "note", "heading":
            let nx = element.x ?? 500
            let ny = element.y ?? 100
            guard let text = element.label, !text.isEmpty else { return ([], nil) }
            let overlay = RovieSketchLabelOverlay(
                id: element.id,
                text: text,
                normalizedPosition: CGPoint(x: nx, y: ny),
                colorHex: element.color ?? "#2563EB",
                isHeading: kind == "heading"
            )
            return ([], overlay)

        default:
            return ([], nil)
        }
    }

    private static func interpolateSegment(
        from a: CGPoint,
        to b: CGPoint,
        steps: Int,
        arcBow: CGFloat
    ) -> [CGPoint] {
        let count = max(2, steps)
        var out: [CGPoint] = []
        for i in 0...count {
            let t = CGFloat(i) / CGFloat(count)
            let bow = sin(t * .pi) * arcBow
            let x = a.x + (b.x - a.x) * t
            let y = a.y + (b.y - a.y) * t + bow
            out.append(CGPoint(x: x, y: y))
        }
        return out
    }

    private static func interpolatePolygon(
        _ vertices: [CGPoint],
        stepsPerEdge: Int,
        wobble: CGFloat
    ) -> [CGPoint] {
        guard vertices.count >= 2 else { return vertices }
        var out: [CGPoint] = []
        for idx in 0..<(vertices.count - 1) {
            let seg = interpolateSegment(
                from: vertices[idx],
                to: vertices[idx + 1],
                steps: stepsPerEdge,
                arcBow: (idx % 2 == 0 ? wobble : -wobble)
            )
            if !out.isEmpty {
                out.append(contentsOf: seg.dropFirst())
            } else {
                out.append(contentsOf: seg)
            }
        }
        return out
    }

    static func makeStroke(
        points: [CGPoint],
        inkType: PKInk.InkType,
        color: UIColor,
        width: CGFloat
    ) -> PKStroke {
        let ink = PKInk(inkType, color: color)
        let size = CGSize(width: width, height: width)
        var offset: TimeInterval = 0
        let controlPoints: [PKStrokePoint] = points.map { pt in
            offset += 0.008
            return PKStrokePoint(
                location: pt,
                timeOffset: offset,
                size: size,
                opacity: 1.0,
                force: 1.0,
                azimuth: 0,
                altitude: .pi / 2
            )
        }
        let path = PKStrokePath(controlPoints: controlPoints, creationDate: Date())
        return PKStroke(ink: ink, path: path)
    }

    /// Creates a partial slice of a PKStroke with `fraction` (0...1) of its control points
    /// so we can animate the pen drawing across the canvas at 60fps.
    static func partialStroke(_ stroke: PKStroke, fraction: CGFloat) -> PKStroke? {
        let allPoints = Array(stroke.path)
        guard allPoints.count >= 2 else { return stroke }
        let clamped = max(0.0, min(1.0, fraction))
        let count = max(2, Int(ceil(CGFloat(allPoints.count) * clamped)))
        let slice = Array(allPoints.prefix(count))
        let path = PKStrokePath(controlPoints: slice, creationDate: stroke.path.creationDate)
        return PKStroke(ink: stroke.ink, path: path, transform: stroke.transform, mask: stroke.mask)
    }
}

// MARK: - Sketch Session Coordinator / ViewModel

@MainActor
final class RovieSketchSessionModel: ObservableObject {

    static let shared = RovieSketchSessionModel()

    @Published var isPresented: Bool = false
    @Published var sessionId: String = UUID().uuidString.prefix(8).lowercased()
    @Published var chatSessionId: String? = nil
    @Published var scene: RovieSketchScene = RovieSketchScene(title: "Sketch Pad", steps: [])
    @Published var currentStepIndex: Int = 0
    @Published var isPlaying: Bool = false
    @Published var isSpeaking: Bool = false
    @Published var playbackSpeed: Float = 1.0

    // Drawing state
    @Published var activeToolKind: ToolKind = .pen
    @Published var activeInkColorHex: String = "#2563EB"
    @Published var showNativeToolPicker: Bool = false
    @Published var followUpPrompt: String = ""
    @Published var isSendingFollowUp: Bool = false

    // Live PKCanvasView reference for snapshots and stroke animation
    weak var canvasView: PKCanvasView?
    var toolPicker = PKToolPicker()

    enum ToolKind: String, CaseIterable {
        case pen
        case highlighter
        case eraser
    }

    /// Strokes generated by the AI tutor (replaced during animation/stepping)
    private(set) var aiGeneratedStrokeCount: Int = 0
    /// User's own freehand strokes preserved across step changes
    var userStrokes: [PKStroke] = []
    /// Visible labels up to the current step
    @Published var visibleLabels: [RovieSketchLabelOverlay] = []

    private var animationTimer: Timer?
    private var audioPlayer: AVAudioPlayer?
    private var speechDelegate: SketchAudioDelegate?
    private var playbackTask: Task<Void, Never>?
    private var isProgrammaticCanvasUpdate = false

    private init() {}

    // MARK: - Load & Present Scene

    func openBlank(chatSessionId: String? = nil) {
        if let chatSessionId, !chatSessionId.isEmpty {
            self.chatSessionId = chatSessionId
        }
        if scene.steps.isEmpty {
            self.scene = RovieSketchScene(title: "Sketch Pad", steps: [])
        }
        self.isPresented = true
    }

    func presentScene(_ newScene: RovieSketchScene, chatSessionId: String? = nil, autoPlay: Bool = true) {
        stopPlayback()
        self.sessionId = UUID().uuidString.prefix(8).lowercased()
        if let chatSessionId, !chatSessionId.isEmpty {
            self.chatSessionId = chatSessionId
        }
        if let requestedVoice = newScene.voice, KokoroVoiceEngine.isKokoroVoiceId(requestedVoice) {
            KokoroVoiceEngine.shared.selectedVoiceId = KokoroVoiceEngine.preset(for: requestedVoice).id
        }
        self.scene = newScene
        self.currentStepIndex = 0
        self.userStrokes = []
        self.visibleLabels = []
        self.aiGeneratedStrokeCount = 0
        if let cv = canvasView {
            isProgrammaticCanvasUpdate = true
            cv.drawing = PKDrawing()
            isProgrammaticCanvasUpdate = false
        }
        self.isPresented = true

        if autoPlay && !newScene.steps.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.startPlayingFrom(stepIndex: 0)
            }
        }
    }

    func appendStep(_ step: RovieSketchStep, autoPlayNewStep: Bool = true) {
        let newIndex = scene.steps.count
        scene.steps.append(step)
        if !isPresented {
            isPresented = true
        }
        if autoPlayNewStep {
            startPlayingFrom(stepIndex: newIndex)
        }
    }

    // MARK: - Tool Selection

    func applySelectedTool() {
        guard let cv = canvasView else { return }
        let color = RoviePKStrokeBuilder.parseColor(activeInkColorHex, defaultColor: .systemBlue)
        switch activeToolKind {
        case .pen:
            cv.tool = PKInkingTool(.pen, color: color, width: 3.5)
        case .highlighter:
            cv.tool = PKInkingTool(.marker, color: color.withAlphaComponent(0.35), width: 18.0)
        case .eraser:
            cv.tool = PKEraserTool(.vector)
        }
    }

    func toggleNativePicker() {
        guard let cv = canvasView else { return }
        showNativeToolPicker.toggle()
        toolPicker.setVisible(showNativeToolPicker, forFirstResponder: cv)
        if showNativeToolPicker {
            cv.becomeFirstResponder()
        }
    }

    func undoLastUserStroke() {
        guard !userStrokes.isEmpty else { return }
        userStrokes.removeLast()
        rebuildCanvasUpToStep(currentStepIndex, animatedFractionForCurrent: 1.0)
    }

    func clearAll() {
        stopPlayback()
        userStrokes.removeAll()
        visibleLabels.removeAll()
        aiGeneratedStrokeCount = 0
        if let cv = canvasView {
            isProgrammaticCanvasUpdate = true
            cv.drawing = PKDrawing()
            isProgrammaticCanvasUpdate = false
        }
    }

    func recordUserCanvasChange(_ drawing: PKDrawing) {
        guard !isProgrammaticCanvasUpdate else { return }
        let all = drawing.strokes
        if all.count >= aiGeneratedStrokeCount {
            userStrokes = Array(all.dropFirst(aiGeneratedStrokeCount))
        } else {
            // User erased some AI strokes
            userStrokes = []
            aiGeneratedStrokeCount = all.count
        }
    }

    // MARK: - Step & Voice Playback Synchronization

    func togglePlayPause() {
        if isPlaying {
            stopPlayback()
        } else {
            startPlayingFrom(stepIndex: currentStepIndex)
        }
    }

    func stepBackward() {
        stopPlayback()
        guard !scene.steps.isEmpty else { return }
        currentStepIndex = max(0, currentStepIndex - 1)
        rebuildCanvasUpToStep(currentStepIndex, animatedFractionForCurrent: 1.0)
    }

    func stepForward() {
        stopPlayback()
        guard !scene.steps.isEmpty else { return }
        if currentStepIndex + 1 < scene.steps.count {
            currentStepIndex += 1
        }
        rebuildCanvasUpToStep(currentStepIndex, animatedFractionForCurrent: 1.0)
    }

    func replayCurrentStep() {
        stopPlayback()
        guard !scene.steps.isEmpty else { return }
        playSingleStep(at: currentStepIndex, autoAdvance: false)
    }

    func stopPlayback() {
        playbackTask?.cancel()
        playbackTask = nil
        animationTimer?.invalidate()
        animationTimer = nil
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        isSpeaking = false
    }

    func startPlayingFrom(stepIndex: Int) {
        stopPlayback()
        guard !scene.steps.isEmpty else { return }
        let startIdx = max(0, min(scene.steps.count - 1, stepIndex))
        isPlaying = true
        playSingleStep(at: startIdx, autoAdvance: true)
    }

    private func playSingleStep(at index: Int, autoAdvance: Bool) {
        guard index >= 0 && index < scene.steps.count else {
            isPlaying = false
            isSpeaking = false
            return
        }

        currentStepIndex = index
        let step = scene.steps[index]

        playbackTask?.cancel()
        playbackTask = Task { @MainActor [weak self] in
            guard let self else { return }

            // 1. Synthesize speech for this step via KokoroVoiceEngine
            var wavData: Data? = nil
            var speechDuration: TimeInterval = 2.4
            if let text = step.speak?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                self.isSpeaking = true
                wavData = try? await KokoroVoiceEngine.synthesizeWAV(
                    text: text,
                    voiceId: KokoroVoiceEngine.shared.selectedVoiceId,
                    speed: self.playbackSpeed
                )
            }
            if Task.isCancelled { return }

            // 2. Start audio playback & measure exact duration so stroke animation matches speech
            var audioFinishedSignal: AsyncStream<Void>? = nil
            if let data = wavData {
                try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
                try? AVAudioSession.sharedInstance().setActive(true)
                if let player = try? AVAudioPlayer(data: data) {
                    player.enableRate = true
                    player.rate = self.playbackSpeed
                    player.volume = VoiceOutputPreferences.readAloudVolume
                    speechDuration = max(1.2, player.duration / Double(self.playbackSpeed))
                    let (stream, cont) = AsyncStream<Void>.makeStream()
                    audioFinishedSignal = stream
                    let delegate = SketchAudioDelegate {
                        cont.yield(())
                        cont.finish()
                    }
                    self.speechDelegate = delegate
                    player.delegate = delegate
                    player.prepareToPlay()
                    player.play()
                    self.audioPlayer = player
                }
            }

            // 3. Animate the PencilKit strokes for this step over the first ~75% of the speech duration
            let drawDuration = min(max(0.85, speechDuration * 0.72), 4.2)
            await self.animateStepStrokes(stepIndex: index, duration: drawDuration)
            if Task.isCancelled { return }

            // 4. Wait for speech to finish if still speaking
            if let stream = audioFinishedSignal, self.audioPlayer?.isPlaying == true {
                for await _ in stream { break }
            } else {
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
            if Task.isCancelled { return }

            self.isSpeaking = false

            // 5. Auto-advance to next step if playing full sequence
            if autoAdvance && self.isPlaying && (index + 1) < self.scene.steps.count {
                try? await Task.sleep(nanoseconds: 280_000_000)
                if !Task.isCancelled && self.isPlaying {
                    self.playSingleStep(at: index + 1, autoAdvance: true)
                }
            } else {
                self.isPlaying = false
            }
        }
    }

    private func animateStepStrokes(stepIndex: Int, duration: TimeInterval) async {
        let frames = max(12, Int(duration * 36.0))
        let frameNs = UInt64((duration / Double(frames)) * 1_000_000_000)
        for frame in 1...frames {
            if Task.isCancelled { return }
            let frac = CGFloat(frame) / CGFloat(frames)
            rebuildCanvasUpToStep(stepIndex, animatedFractionForCurrent: frac)
            try? await Task.sleep(nanoseconds: frameNs)
        }
        rebuildCanvasUpToStep(stepIndex, animatedFractionForCurrent: 1.0)
    }

    func rebuildCanvasUpToStep(_ targetStep: Int, animatedFractionForCurrent: CGFloat) {
        guard let cv = canvasView else { return }
        let size = cv.bounds.size.width > 40 ? cv.bounds.size : CGSize(width: 360, height: 480)
        let isDark = cv.traitCollection.userInterfaceStyle == .dark

        var priorStrokes: [PKStroke] = []
        var labels: [RovieSketchLabelOverlay] = []

        let cappedStep = min(targetStep, max(0, scene.steps.count - 1))
        if !scene.steps.isEmpty {
            for idx in 0...cappedStep {
                let step = scene.steps[idx]
                var stepStrokes: [PKStroke] = []
                for el in step.elements {
                    let built = RoviePKStrokeBuilder.buildStrokes(for: el, in: size, isDarkCanvas: isDark)
                    stepStrokes.append(contentsOf: built.strokes)
                    if let lbl = built.label {
                        labels.append(lbl)
                    }
                }

                if idx < cappedStep || animatedFractionForCurrent >= 0.999 {
                    priorStrokes.append(contentsOf: stepStrokes)
                } else {
                    // Progressive stroke-by-stroke reveal for the active step
                    let totalStrokes = stepStrokes.count
                    if totalStrokes > 0 {
                        let scaledProgress = animatedFractionForCurrent * CGFloat(totalStrokes)
                        let completedCount = Int(floor(scaledProgress))
                        let activeStrokeFraction = scaledProgress - CGFloat(completedCount)

                        for sIdx in 0..<min(completedCount, totalStrokes) {
                            priorStrokes.append(stepStrokes[sIdx])
                        }
                        if completedCount < totalStrokes,
                           let partial = RoviePKStrokeBuilder.partialStroke(
                               stepStrokes[completedCount],
                               fraction: activeStrokeFraction
                           ) {
                            priorStrokes.append(partial)
                        }
                    }
                }
            }
        }

        self.visibleLabels = labels
        self.aiGeneratedStrokeCount = priorStrokes.count

        isProgrammaticCanvasUpdate = true
        cv.drawing = PKDrawing(strokes: priorStrokes + userStrokes)
        isProgrammaticCanvasUpdate = false
    }

    // MARK: - Snapshot & Ask Rovie Vision Loop

    func exportSnapshotImage() -> UIImage? {
        guard let cv = canvasView else { return nil }
        let bounds = cv.bounds.width > 10 ? cv.bounds : CGRect(x: 0, y: 0, width: 390, height: 520)
        let isDark = cv.traitCollection.userInterfaceStyle == .dark

        let renderer = UIGraphicsImageRenderer(bounds: bounds)
        return renderer.image { ctx in
            // Background
            let bgColor = isDark ? UIColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1.0)
                                 : UIColor(red: 0.99, green: 0.99, blue: 0.98, alpha: 1.0)
            bgColor.setFill()
            ctx.fill(bounds)

            // Draw PKDrawing strokes
            let pkImage = cv.drawing.image(from: bounds, scale: UIScreen.main.scale)
            pkImage.draw(in: bounds)

            // Draw text labels onto the snapshot so the vision model sees both strokes and text
            for label in visibleLabels {
                let pt = RoviePKStrokeBuilder.mapPoint(label.normalizedPosition.x, label.normalizedPosition.y, in: bounds.size)
                let font = UIFont.systemFont(ofSize: label.isHeading ? 16 : 13, weight: .semibold)
                let textColor = isDark ? UIColor.white : UIColor(red: 0.1, green: 0.12, blue: 0.16, alpha: 1.0)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: textColor
                ]
                let nsText = label.text as NSString
                let textSize = nsText.size(withAttributes: attrs)
                let rect = CGRect(
                    x: pt.x - textSize.width / 2,
                    y: pt.y - textSize.height / 2,
                    width: textSize.width,
                    height: textSize.height
                )
                let pillRect = rect.insetBy(dx: -8, dy: -4)
                let pillBg = (isDark ? UIColor.black : UIColor.white).withAlphaComponent(0.86)
                pillBg.setFill()
                UIBezierPath(roundedRect: pillRect, cornerRadius: 6).fill()
                nsText.draw(in: rect, withAttributes: attrs)
            }
        }
    }

    func saveSnapshotToHostPath(_ hostPath: String) -> [String: Any]? {
        guard let image = exportSnapshotImage(),
              let pngData = image.pngData() else {
            return nil
        }
        let url = URL(fileURLWithPath: hostPath)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try pngData.write(to: url, options: .atomic)
            return [
                "ok": true,
                "path": hostPath,
                "bytes": pngData.count,
                "width": Int(image.size.width * image.scale),
                "height": Int(image.size.height * image.scale),
                "user_strokes_count": userStrokes.count,
                "step_index": currentStepIndex
            ]
        } catch {
            return nil
        }
    }

    func sendFollowUpToSmartModel() {
        let trimmed = followUpPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let promptText = trimmed.isEmpty
            ? "Look at my annotations on the sketch pad and explain or draw the next step using rovie-sketch."
            : "\(trimmed) (Respond and update the board using rovie-sketch add-step or explain.)"

        guard !isSendingFollowUp else { return }
        isSendingFollowUp = true

        // Save snapshot PNG so the chosen smart LLM sees both the diagram and the user's hand-drawn strokes
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let offloadsDir = docs.appendingPathComponent("alpine-rootfs/data/var/minis/offloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: offloadsDir, withIntermediateDirectories: true)
        let hostSnapshotURL = offloadsDir.appendingPathComponent("sketch_\(ts).png")

        var attachments: [String] = []
        if saveSnapshotToHostPath(hostSnapshotURL.path) != nil {
            attachments.append(hostSnapshotURL.path)
        }

        let targetSessionId = chatSessionId ?? ViewModelCache.recentSessionsSeed.first?.id
        followUpPrompt = ""

        Task.detached {
            _ = SessionsOffloadBridge.sendPrompt(
                sessionId: targetSessionId,
                prompt: promptText,
                attachmentPaths: attachments,
                modelEntryId: nil,
                source: "sketch"
            )
            await MainActor.run {
                RovieSketchSessionModel.shared.isSendingFollowUp = false
            }
        }
    }
}

private final class SketchAudioDelegate: NSObject, AVAudioPlayerDelegate {
    private let onFinish: () -> Void
    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish()
    }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        onFinish()
    }
}

// MARK: - Native PKCanvasView Wrapper

private struct RoviePKCanvasRepresentable: UIViewRepresentable {
    @ObservedObject var model: RovieSketchSessionModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.drawingPolicy = .anyInput
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.alwaysBounceVertical = false
        canvas.alwaysBounceHorizontal = false
        canvas.delegate = context.coordinator

        model.canvasView = canvas
        model.toolPicker.addObserver(canvas)
        model.applySelectedTool()

        DispatchQueue.main.async {
            model.rebuildCanvasUpToStep(model.currentStepIndex, animatedFractionForCurrent: 1.0)
        }
        return canvas
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        if model.canvasView !== uiView {
            model.canvasView = uiView
        }
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let model: RovieSketchSessionModel
        init(model: RovieSketchSessionModel) {
            self.model = model
        }
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            Task { @MainActor in
                model.recordUserCanvasChange(canvasView.drawing)
            }
        }
    }
}

// MARK: - Sketch Pad Sheet UI

struct RovieSketchPadSheet: View {
    @ObservedObject var model = RovieSketchSessionModel.shared
    @Environment(\.colorScheme) private var colorScheme

    private let inkColors: [String] = [
        "#2563EB", "#10B981", "#F59E0B", "#EF4444", "#8B5CF6", "#EC4899"
    ]

    var body: some View {
        VStack(spacing: 0) {
            topHeaderBar
            Divider().opacity(0.4)

            // Main Interactive PencilKit Canvas + Labels Overlay
            GeometryReader { geo in
                ZStack {
                    canvasDotGridBackground

                    RoviePKCanvasRepresentable(model: model)
                        .frame(width: geo.size.width, height: geo.size.height)

                    // Crisp typography labels positioned at normalized coordinates
                    ForEach(model.visibleLabels) { label in
                        let pt = RoviePKStrokeBuilder.mapPoint(
                            label.normalizedPosition.x,
                            label.normalizedPosition.y,
                            in: geo.size
                        )
                        Text(label.text)
                            .font(.system(size: label.isHeading ? 15 : 12.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(.ultraThinMaterial)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .strokeBorder(
                                                Color(uiColor: RoviePKStrokeBuilder.parseColor(label.colorHex, defaultColor: .systemBlue)).opacity(0.45),
                                                lineWidth: 1
                                            )
                                    )
                            )
                            .position(x: pt.x, y: pt.y)
                            .allowsHitTesting(false)
                            .transition(.scale(scale: 0.9).combined(with: .opacity))
                    }

                    // Floating Quick Drawing Palette (top-right inside canvas)
                    VStack {
                        HStack {
                            Spacer()
                            quickDrawingToolbar
                        }
                        Spacer()
                    }
                    .padding(12)
                }
            }

            // Active Step Narration Caption & Step Scrubber
            if !model.scene.steps.isEmpty {
                stepPlaybackBar
            }

            Divider().opacity(0.4)
            followUpBar
        }
        .background(colorScheme == .dark ? Color(red: 0.07, green: 0.08, blue: 0.10) : Color(red: 0.985, green: 0.985, blue: 0.975))
        .onDisappear {
            model.stopPlayback()
        }
    }

    // MARK: - Top Header Bar

    private var topHeaderBar: some View {
        HStack(spacing: 8) {
            Text(model.scene.title ?? "Sketch Pad")
                .font(.system(size: 16, weight: .semibold))
                .lineLimit(1)

            Spacer()

            // Direct 1-tap Kokoro-82M download / status pill (isolated from Menu & Canvas)
            KokoroDownloadHeaderPill()

            // Kokoro Voice Selector Menu (never re-evaluates on progress ticks)
            KokoroVoiceSelectorMenu(model: model)

            Button {
                model.clearAll()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
            }

            Button {
                model.stopPlayback()
                model.isPresented = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(Color.primary.opacity(0.08), in: Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Quick Drawing Toolbar

    private var quickDrawingToolbar: some View {
        HStack(spacing: 8) {
            ForEach(inkColors, id: \.self) { hex in
                let c = Color(uiColor: RoviePKStrokeBuilder.parseColor(hex, defaultColor: .systemBlue))
                Button {
                    model.activeInkColorHex = hex
                    if model.activeToolKind == .eraser {
                        model.activeToolKind = .pen
                    }
                    model.applySelectedTool()
                } label: {
                    Circle()
                        .fill(c)
                        .frame(width: 18, height: 18)
                        .overlay(
                            Circle()
                                .strokeBorder(Color.primary, lineWidth: model.activeInkColorHex == hex && model.activeToolKind != .eraser ? 2 : 0)
                                .padding(-2)
                        )
                }
            }

            Divider().frame(height: 16)

            Button {
                model.activeToolKind = .pen
                model.applySelectedTool()
            } label: {
                Image(systemName: "pencil.tip")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(model.activeToolKind == .pen ? Color.accentColor : .secondary)
                    .frame(width: 28, height: 28)
            }

            Button {
                model.activeToolKind = .highlighter
                model.applySelectedTool()
            } label: {
                Image(systemName: "highlighter")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(model.activeToolKind == .highlighter ? Color.accentColor : .secondary)
                    .frame(width: 28, height: 28)
            }

            Button {
                model.activeToolKind = .eraser
                model.applySelectedTool()
            } label: {
                Image(systemName: "eraser.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(model.activeToolKind == .eraser ? Color.accentColor : .secondary)
                    .frame(width: 28, height: 28)
            }

            Button {
                model.undoLastUserStroke()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(model.userStrokes.isEmpty ? .tertiary : .secondary)
                    .frame(width: 28, height: 28)
            }
            .disabled(model.userStrokes.isEmpty)

            Button {
                model.toggleNativePicker()
            } label: {
                Image(systemName: "scribble.variable")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(model.showNativeToolPicker ? Color.accentColor : .secondary)
                    .frame(width: 28, height: 28)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }

    // MARK: - Step & Voice Scrubber Bar

    private var stepPlaybackBar: some View {
        let currentStep = model.scene.steps[min(model.currentStepIndex, model.scene.steps.count - 1)]
        return VStack(alignment: .leading, spacing: 8) {
            if let speak = currentStep.speak, !speak.isEmpty {
                Text(speak)
                    .font(.system(size: 13.5, weight: .regular))
                    .foregroundStyle(.primary.opacity(0.88))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 14) {
                Button {
                    model.togglePlayPause()
                } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Color.accentColor, in: Circle())
                }

                Button {
                    model.stepBackward()
                } label: {
                    Image(systemName: "backward.step.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(model.currentStepIndex > 0 ? .primary : .tertiary)
                }
                .disabled(model.currentStepIndex == 0)

                Text("\(model.currentStepIndex + 1) / \(model.scene.steps.count)")
                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)

                Button {
                    model.stepForward()
                } label: {
                    Image(systemName: "forward.step.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(model.currentStepIndex + 1 < model.scene.steps.count ? .primary : .tertiary)
                }
                .disabled(model.currentStepIndex + 1 >= model.scene.steps.count)

                if let stepTitle = currentStep.title, !stepTitle.isEmpty {
                    Text(stepTitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button {
                    model.replayCurrentStep()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.03))
    }

    // MARK: - Follow-Up / Ask Rovie Input Bar

    private var followUpBar: some View {
        HStack(spacing: 10) {
            TextField("Circle anything or ask Rovie…", text: $model.followUpPrompt)
                .font(.system(size: 14))
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .onSubmit {
                    model.sendFollowUpToSmartModel()
                }

            Button {
                model.sendFollowUpToSmartModel()
            } label: {
                if model.isSendingFollowUp {
                    ProgressView()
                        .frame(width: 34, height: 34)
                } else {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .disabled(model.isSendingFollowUp)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Subtle Dot Grid Canvas Background

    private var canvasDotGridBackground: some View {
        Canvas { context, size in
            let spacing: CGFloat = 24
            let dotColor = colorScheme == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.08)
            var y: CGFloat = spacing
            while y < size.height {
                var x: CGFloat = spacing
                while x < size.width {
                    let rect = CGRect(x: x - 1, y: y - 1, width: 2, height: 2)
                    context.fill(Path(ellipseIn: rect), with: .color(dotColor))
                    x += spacing
                }
                y += spacing
            }
        }
        .allowsHitTesting(false)
    }
}

struct RovieSketchPadSheetModifier: ViewModifier {
    @ObservedObject private var sketchModel = RovieSketchSessionModel.shared

    func body(content: Content) -> some View {
        content.sheet(isPresented: $sketchModel.isPresented) {
            RovieSketchPadSheet()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }
}

// MARK: - Isolated Kokoro Download Pill & Voice Selector Menu

struct KokoroDownloadHeaderPill: View {
    @ObservedObject private var kokoro = KokoroVoiceEngine.shared

    var body: some View {
        if kokoro.isOfflinePackInstalled {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.green)
                Text("Offline")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.green.opacity(0.10), in: Capsule())
        } else if kokoro.isDownloadingPack {
            Button {
                kokoro.cancelDownload()
            } label: {
                HStack(spacing: 5) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("\(Int(kokoro.downloadProgress * 100))% · \(Int(kokoro.downloadedMB))MB")
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.accentColor)
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Color.accentColor.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
        } else {
            Button {
                kokoro.downloadOfflinePack()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Get Kokoro")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Color.accentColor.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }
}

private struct KokoroVoiceSelectorMenu: View {
    @ObservedObject var model: RovieSketchSessionModel
    @AppStorage("rovie.kokoro.selectedVoiceId") private var selectedVoiceId: String = "af_heart"

    private var currentPreset: KokoroVoiceEngine.VoicePreset {
        KokoroVoiceEngine.preset(for: selectedVoiceId)
    }

    var body: some View {
        Menu {
            Section("Kokoro-82M Voice") {
                ForEach(KokoroVoiceEngine.presets) { preset in
                    Button {
                        KokoroVoiceEngine.shared.selectedVoiceId = preset.id
                        if model.isPlaying {
                            model.replayCurrentStep()
                        }
                    } label: {
                        HStack {
                            Text("\(preset.name) · \(preset.accent)")
                            if selectedVoiceId == preset.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }

            Section("Speed") {
                ForEach([Float(1.0), Float(1.25), Float(1.5)], id: \.self) { rate in
                    Button {
                        model.playbackSpeed = rate
                    } label: {
                        HStack {
                            Text(String(format: "%.2gx", rate))
                            if abs(model.playbackSpeed - rate) < 0.05 {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }

            if KokoroVoiceEngine.checkOfflineFilesExist() {
                Section("Offline Engine") {
                    Button(role: .destructive) {
                        KokoroVoiceEngine.shared.removeOfflinePack()
                    } label: {
                        Label("Remove Offline Pack", systemImage: "trash")
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: model.isSpeaking ? "waveform.circle.fill" : "waveform")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(model.isSpeaking ? Color.accentColor : .primary)
                Text(currentPreset.name.replacingOccurrences(of: "Kokoro · ", with: ""))
                    .font(.system(size: 13, weight: .medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.07), in: Capsule())
        }
    }
}

