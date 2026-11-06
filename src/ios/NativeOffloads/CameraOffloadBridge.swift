//
//  CameraOffloadBridge.swift
//  MinisApp
//
//  Swift bridge for AVCapture — enables the guest agent to capture photos
//  directly using the device camera.
//

import Foundation
import AVFoundation
import UIKit

@objc public class CameraOffloadBridge: NSObject {

    private static let cameraQueue = DispatchQueue(label: "africa.rovie.camera.queue", qos: .userInitiated)

    @objc public static func authorizationStatus() -> String {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not_determined"
        @unknown default: return "unknown"
        }
    }

    @objc public static func listDevices() -> [NSDictionary] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInWideAngleCamera,
                .builtInUltraWideCamera,
                .builtInTelephotoCamera
            ],
            mediaType: .video,
            position: .unspecified
        )

        return discovery.devices.map { dev in
            let pos: String
            switch dev.position {
            case .front: pos = "front"
            case .back: pos = "back"
            default: pos = "unspecified"
            }
            return [
                "id": dev.uniqueID,
                "name": dev.localizedName,
                "position": pos,
                "hasFlash": dev.hasFlash,
                "hasTorch": dev.hasTorch
            ] as NSDictionary
        }
    }

    @objc public static func capturePhoto(
        position: String,
        flashMode: String,
        outputPath: String,
        completion: @escaping (NSDictionary) -> Void
    ) {
        let auth = AVCaptureDevice.authorizationStatus(for: .video)
        if auth == .notDetermined {
            let sem = DispatchSemaphore(value: 0)
            var granted = false
            AVCaptureDevice.requestAccess(for: .video) { g in
                granted = g
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + 15)
            if !granted {
                completion([
                    "ok": false,
                    "error": "permission_denied",
                    "message": "Camera access was denied by the user."
                ] as NSDictionary)
                return
            }
        } else if auth != .authorized {
            completion([
                "ok": false,
                "error": "permission_denied",
                "message": "Camera access is not authorized (\(authorizationStatus()))."
            ] as NSDictionary)
            return
        }

        cameraQueue.async {
            let targetPosition: AVCaptureDevice.Position = (position.lowercased() == "front") ? .front : .back
            let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: targetPosition)
                ?? AVCaptureDevice.default(for: .video)

            guard let captureDevice = device else {
                completion([
                    "ok": false,
                    "error": "device_not_found",
                    "message": "No camera device found for position '\(position)'."
                ] as NSDictionary)
                return
            }

            let session = AVCaptureSession()
            session.beginConfiguration()
            if session.canSetSessionPreset(.photo) {
                session.sessionPreset = .photo
            }

            guard let input = try? AVCaptureDeviceInput(device: captureDevice), session.canAddInput(input) else {
                session.commitConfiguration()
                completion([
                    "ok": false,
                    "error": "configuration_failed",
                    "message": "Could not add camera input for device '\(captureDevice.localizedName)'."
                ] as NSDictionary)
                return
            }
            session.addInput(input)

            let photoOutput = AVCapturePhotoOutput()
            guard session.canAddOutput(photoOutput) else {
                session.commitConfiguration()
                completion([
                    "ok": false,
                    "error": "configuration_failed",
                    "message": "Could not add photo output to AVCaptureSession."
                ] as NSDictionary)
                return
            }
            session.addOutput(photoOutput)
            session.commitConfiguration()

            session.startRunning()

            // Brief delay to allow auto-exposure and auto-white-balance to converge
            Thread.sleep(forTimeInterval: 0.35)

            let photoSettings = AVCapturePhotoSettings()
            if captureDevice.hasFlash {
                switch flashMode.lowercased() {
                case "on": photoSettings.flashMode = .on
                case "auto": photoSettings.flashMode = .auto
                default: photoSettings.flashMode = .off
                }
            }

            let captureCoordinator = PhotoCaptureCoordinator(
                session: session,
                outputPath: outputPath,
                position: position,
                completion: completion
            )
            // Retain coordinator during capture
            photoOutput.capturePhoto(with: photoSettings, delegate: captureCoordinator)
        }
    }
}

/// Internal coordinator implementing AVCapturePhotoCaptureDelegate
private class PhotoCaptureCoordinator: NSObject, AVCapturePhotoCaptureDelegate {
    private let session: AVCaptureSession
    private let outputPath: String
    private let position: String
    private let completion: (NSDictionary) -> Void
    private var selfRetain: PhotoCaptureCoordinator?

    init(
        session: AVCaptureSession,
        outputPath: String,
        position: String,
        completion: @escaping (NSDictionary) -> Void
    ) {
        self.session = session
        self.outputPath = outputPath
        self.position = position
        self.completion = completion
        super.init()
        self.selfRetain = self
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        session.stopRunning()
        defer { selfRetain = nil }

        if let error = error {
            completion([
                "ok": false,
                "error": "capture_failed",
                "message": error.localizedDescription
            ] as NSDictionary)
            return
        }

        guard let data = photo.fileDataRepresentation() else {
            completion([
                "ok": false,
                "error": "no_data",
                "message": "Failed to extract image data representation from AVCapturePhoto."
            ] as NSDictionary)
            return
        }

        let outputURL = URL(fileURLWithPath: outputPath)
        let parentDir = outputURL.deletingLastPathComponent()

        do {
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            try data.write(to: outputURL, options: .atomic)

            var width = 0
            var height = 0
            if let image = UIImage(data: data) {
                width = Int(image.size.width * image.scale)
                height = Int(image.size.height * image.scale)
            }

            completion([
                "ok": true,
                "path": outputPath,
                "bytes": data.count,
                "width": width,
                "height": height,
                "position": position,
                "timestamp": ISO8601DateFormatter().string(from: Date())
            ] as NSDictionary)
        } catch {
            completion([
                "ok": false,
                "error": "write_failed",
                "message": error.localizedDescription
            ] as NSDictionary)
        }
    }
}

