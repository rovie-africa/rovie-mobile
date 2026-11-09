//
//  SketchOffloadBridge.swift
//  MinisApp
//
//  Swift bridge for `rovie-sketch` / `apple-sketch` offload.
//  Presents the native PencilKit Sketch Pad + Kokoro-82M Voice Tutor sheet,
//  animates AI-generated steps, and exports canvas snapshots for vision models.
//

import Foundation
import SwiftUI
import UIKit
import Combine

@MainActor @objc public class SketchOffloadBridge: NSObject {

    private static weak var hostedController: UIViewController?
    private static var dismissCancellable: AnyCancellable?

    @objc public static func openEmptySketchPad(
        title: String?,
        voice: String?,
        completion: @escaping (NSDictionary?, NSString?) -> Void
    ) {
        let scene = RovieSketchScene(
            title: (title?.isEmpty == false) ? title : "Sketch Pad",
            voice: voice,
            steps: []
        )
        let activeSid = ViewModelCache.recentSessionsSeed.first?.id
        RovieSketchSessionModel.shared.presentScene(scene, chatSessionId: activeSid, autoPlay: false)
        ensureSheetPresented()

        let data: NSDictionary = [
            "session_id": RovieSketchSessionModel.shared.sessionId,
            "title": scene.title ?? "Sketch Pad",
            "voice": KokoroVoiceEngine.shared.selectedVoiceId,
            "status": "opened"
        ]
        completion(data, nil)
    }

    @objc public static func explainWithJSON(
        _ jsonString: String,
        voiceOverride: String?,
        completion: @escaping (NSDictionary?, NSString?) -> Void
    ) {
        guard let rawData = jsonString.data(using: .utf8) else {
            completion(nil, "Invalid UTF-8 in sketch JSON" as NSString)
            return
        }

        do {
            var scene = try JSONDecoder().decode(RovieSketchScene.self, from: rawData)
            if let v = voiceOverride, !v.isEmpty {
                scene.voice = v
            }
            let activeSid = ViewModelCache.recentSessionsSeed.first?.id
            ensureSheetPresented()
            RovieSketchSessionModel.shared.presentScene(scene, chatSessionId: activeSid, autoPlay: true)

            let data: NSDictionary = [
                "session_id": RovieSketchSessionModel.shared.sessionId,
                "title": scene.title ?? "Sketch Pad",
                "steps_count": scene.steps.count,
                "voice": KokoroVoiceEngine.shared.selectedVoiceId,
                "status": "playing"
            ]
            completion(data, nil)
        } catch {
            completion(nil, "Failed to parse sketch scene JSON: \(error.localizedDescription)" as NSString)
        }
    }

    @objc public static func addStepWithJSON(
        _ jsonString: String,
        completion: @escaping (NSDictionary?, NSString?) -> Void
    ) {
        guard let rawData = jsonString.data(using: .utf8) else {
            completion(nil, "Invalid UTF-8 in step JSON" as NSString)
            return
        }

        do {
            let step = try JSONDecoder().decode(RovieSketchStep.self, from: rawData)
            ensureSheetPresented()
            RovieSketchSessionModel.shared.appendStep(step, autoPlayNewStep: true)

            let data: NSDictionary = [
                "session_id": RovieSketchSessionModel.shared.sessionId,
                "step_index": max(0, RovieSketchSessionModel.shared.scene.steps.count - 1),
                "steps_count": RovieSketchSessionModel.shared.scene.steps.count,
                "voice": KokoroVoiceEngine.shared.selectedVoiceId,
                "status": "playing"
            ]
            completion(data, nil)
        } catch {
            completion(nil, "Failed to parse sketch step JSON: \(error.localizedDescription)" as NSString)
        }
    }

    @objc public static func captureSnapshot(
        toHostPath hostPath: String,
        guestPath: String,
        completion: @escaping (NSDictionary?, NSString?) -> Void
    ) {
        guard let info = RovieSketchSessionModel.shared.saveSnapshotToHostPath(hostPath) else {
            completion(nil, "Failed to render PencilKit canvas snapshot." as NSString)
            return
        }
        var mutable = info
        mutable["guest_path"] = guestPath
        completion(mutable as NSDictionary, nil)
    }

    @objc public static func clearCanvas() -> NSDictionary {
        RovieSketchSessionModel.shared.clearAll()
        return [
            "session_id": RovieSketchSessionModel.shared.sessionId,
            "status": "cleared"
        ]
    }

    @objc public static func listVoices() -> NSDictionary {
        let engine = KokoroVoiceEngine.shared
        let items: [[String: Any]] = KokoroVoiceEngine.presets.map { p in
            [
                "id": p.id,
                "name": p.name,
                "accent": p.accent,
                "selected": (p.id == engine.selectedVoiceId)
            ]
        }
        return [
            "selected_voice": engine.selectedVoiceId,
            "offline_pack_installed": engine.isOfflinePackInstalled,
            "voices": items
        ]
    }

    // MARK: - Sheet Presentation Helper

    static func ensureSheetPresented() {
        let model = RovieSketchSessionModel.shared
        model.isPresented = true

        if let existing = hostedController, existing.presentingViewController != nil {
            return
        }

        guard let topVC = topViewController() else { return }
        let rootView = RovieSketchPadSheet()
        let hostingVC = UIHostingController(rootView: rootView)
        hostingVC.modalPresentationStyle = .pageSheet
        if let sheet = hostingVC.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 24
        }

        hostedController = hostingVC
        dismissCancellable = model.$isPresented
            .dropFirst()
            .sink { presented in
                if !presented {
                    hostingVC.dismiss(animated: true)
                    hostedController = nil
                }
            }

        topVC.present(hostingVC, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first,
              let rootVC = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
            return nil
        }
        var topVC = rootVC
        while let presented = topVC.presentedViewController {
            topVC = presented
        }
        return topVC
    }
}

