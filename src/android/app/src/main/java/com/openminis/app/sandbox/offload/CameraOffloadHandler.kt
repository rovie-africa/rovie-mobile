package com.openminis.app.sandbox.offload

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.ImageFormat
import android.hardware.camera2.*
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import androidx.core.content.ContextCompat
import com.openminis.app.logging.AppLogger
import com.openminis.app.sandbox.NativeOffloadHandler
import com.openminis.app.sandbox.NativeOffloadRequest
import com.openminis.app.sandbox.NativeOffloadResult
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.text.SimpleDateFormat
import java.util.*
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Host-side implementation of `android-camera` / `rovie-camera` — captures still
 * photos using the device camera via Android Camera2 APIs.
 *
 * Usage:
 *   android-camera snap [--front | --back] [--output <path>]
 *   android-camera devices
 *   android-camera status
 *   android-camera --help
 */
class CameraOffloadHandler(private val context: Context) : NativeOffloadHandler {

    override fun handle(request: NativeOffloadRequest): NativeOffloadResult {
        val rawArgs = request.argv.drop(1)
        if (rawArgs.isEmpty() || rawArgs[0] == "-h" || rawArgs[0] == "--help") {
            return NativeOffloadResult(0, HELP_TEXT)
        }

        val parsedArgs = OffloadArgs(rawArgs)

        // Tri-state permission check
        OffloadGate.enforce("camera", "android-camera", parsedArgs, request)?.let { return it }

        return try {
            when (val sub = rawArgs[0]) {
                "snap", "capture" -> doSnap(rawArgs.drop(1), parsedArgs)
                "devices", "list" -> doDevices(parsedArgs)
                "status" -> doStatus(parsedArgs)
                else -> NativeOffloadResult(2, "android-camera: unknown subcommand '$sub'\n$HELP_TEXT")
            }
        } catch (e: SecurityException) {
            val body = JSONObject()
                .put("ok", false)
                .put("error", "permission_denied")
                .put("message", "Camera permission is denied: ${e.message}")
                .toString()
            NativeOffloadResult(77, OffloadOutput.formatBody(body, parsedArgs) + "\n")
        } catch (e: Throwable) {
            AppLogger.warning(TAG, "Camera error: ${e.message}")
            val body = JSONObject()
                .put("ok", false)
                .put("error", "camera_error")
                .put("message", e.message ?: "Unknown camera error")
                .toString()
            NativeOffloadResult(1, OffloadOutput.formatBody(body, parsedArgs) + "\n")
        }
    }

    private fun doStatus(args: OffloadArgs): NativeOffloadResult {
        val hasPermission = ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.CAMERA
        ) == PackageManager.PERMISSION_GRANTED

        val body = JSONObject()
            .put("ok", true)
            .put("authorized", hasPermission)
            .put("status", if (hasPermission) "authorized" else "denied")
            .toString()

        return NativeOffloadResult(0, OffloadOutput.formatBody(body, args) + "\n")
    }

    private fun doDevices(args: OffloadArgs): NativeOffloadResult {
        val cameraManager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val devices = JSONArray()

        for (id in cameraManager.cameraIdList) {
            val chars = cameraManager.getCameraCharacteristics(id)
            val facing = chars.get(CameraCharacteristics.LENS_FACING)
            val pos = when (facing) {
                CameraCharacteristics.LENS_FACING_FRONT -> "front"
                CameraCharacteristics.LENS_FACING_BACK -> "back"
                else -> "external"
            }
            val hasFlash = chars.get(CameraCharacteristics.FLASH_INFO_AVAILABLE) ?: false

            devices.put(
                JSONObject()
                    .put("id", id)
                    .put("position", pos)
                    .put("hasFlash", hasFlash)
            )
        }

        val body = JSONObject()
            .put("ok", true)
            .put("devices", devices)
            .toString()

        return NativeOffloadResult(0, OffloadOutput.formatBody(body, args) + "\n")
    }

    private fun doSnap(options: List<String>, args: OffloadArgs): NativeOffloadResult {
        val hasPermission = ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.CAMERA
        ) == PackageManager.PERMISSION_GRANTED

        if (!hasPermission) {
            val body = JSONObject()
                .put("ok", false)
                .put("error", "permission_denied")
                .put("message", "Camera permission is not granted. Please allow camera access in Settings.")
                .toString()
            return NativeOffloadResult(77, OffloadOutput.formatBody(body, args) + "\n")
        }

        val useFront = options.contains("--front")
        val targetFacing = if (useFront) CameraCharacteristics.LENS_FACING_FRONT else CameraCharacteristics.LENS_FACING_BACK

        var outputPath = ""
        val outputIdx = options.indexOf("--output")
        if (outputIdx in 0 until options.size - 1) {
            outputPath = options[outputIdx + 1]
        }
        if (outputPath.isEmpty()) {
            val ts = System.currentTimeMillis()
            outputPath = "/data/data/${context.packageName}/cache/camera_$ts.jpg"
        }

        val outputFile = File(outputPath)
        outputFile.parentFile?.mkdirs()

        val cameraManager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        var selectedCameraId: String? = null

        for (id in cameraManager.cameraIdList) {
            val chars = cameraManager.getCameraCharacteristics(id)
            if (chars.get(CameraCharacteristics.LENS_FACING) == targetFacing) {
                selectedCameraId = id
                break
            }
        }

        if (selectedCameraId == null && cameraManager.cameraIdList.isNotEmpty()) {
            selectedCameraId = cameraManager.cameraIdList[0]
        }

        if (selectedCameraId == null) {
            val body = JSONObject()
                .put("ok", false)
                .put("error", "no_camera_found")
                .put("message", "No suitable camera found.")
                .toString()
            return NativeOffloadResult(1, OffloadOutput.formatBody(body, args) + "\n")
        }

        val thread = HandlerThread("CameraBackgroundThread").apply { start() }
        val handler = Handler(thread.looper)

        val latch = CountDownLatch(1)
        var captureError: String? = null
        var imageWidth = 1920
        var imageHeight = 1080

        val chars = cameraManager.getCameraCharacteristics(selectedCameraId)
        val map = chars.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
        val jpegSizes = map?.getOutputSizes(ImageFormat.JPEG)
        if (!jpegSizes.isNullOrEmpty()) {
            val chosen = jpegSizes.firstOrNull { it.width in 1280..2560 } ?: jpegSizes[0]
            imageWidth = chosen.width
            imageHeight = chosen.height
        }

        val imageReader = ImageReader.newInstance(imageWidth, imageHeight, ImageFormat.JPEG, 2)
        imageReader.setOnImageAvailableListener({ reader ->
            val image = reader.acquireLatestImage() ?: return@setOnImageAvailableListener
            try {
                val buffer = image.planes[0].buffer
                val bytes = ByteArray(buffer.remaining())
                buffer.get(bytes)
                FileOutputStream(outputFile).use { it.write(bytes) }
                latch.countDown()
            } catch (e: Exception) {
                captureError = e.message
                latch.countDown()
            } finally {
                image.close()
            }
        }, handler)

        try {
            cameraManager.openCamera(selectedCameraId, object : CameraDevice.StateCallback() {
                override fun onOpened(camera: CameraDevice) {
                    try {
                        val sessionCallback = object : CameraCaptureSession.StateCallback() {
                            override fun onConfigured(session: CameraCaptureSession) {
                                try {
                                    val captureBuilder = camera.createCaptureRequest(CameraDevice.TEMPLATE_STILL_CAPTURE).apply {
                                        addTarget(imageReader.surface)
                                        set(CaptureRequest.CONTROL_MODE, CameraMetadata.CONTROL_MODE_AUTO)
                                    }
                                    session.capture(captureBuilder.build(), object : CameraCaptureSession.CaptureCallback() {
                                        override fun onCaptureFailed(session: CameraCaptureSession, request: CaptureRequest, failure: CaptureFailure) {
                                            captureError = "Capture failed: reason=${failure.reason}"
                                            latch.countDown()
                                        }
                                    }, handler)
                                } catch (e: Exception) {
                                    captureError = e.message
                                    latch.countDown()
                                }
                            }

                            override fun onConfigureFailed(session: CameraCaptureSession) {
                                captureError = "Camera session configuration failed."
                                latch.countDown()
                            }
                        }

                        camera.createCaptureSession(listOf(imageReader.surface), sessionCallback, handler)
                    } catch (e: Exception) {
                        captureError = e.message
                        latch.countDown()
                    }
                }

                override fun onDisconnected(camera: CameraDevice) {
                    camera.close()
                }

                override fun onError(camera: CameraDevice, error: Int) {
                    camera.close()
                    captureError = "Camera error code: $error"
                    latch.countDown()
                }
            }, handler)

            val completed = latch.await(15, TimeUnit.SECONDS)
            if (!completed) {
                captureError = "Camera capture timed out."
            }
        } finally {
            thread.quitSafely()
        }

        if (captureError != null || !outputFile.exists() || outputFile.length() == 0L) {
            val body = JSONObject()
                .put("ok", false)
                .put("error", "capture_failed")
                .put("message", captureError ?: "No image captured.")
                .toString()
            return NativeOffloadResult(1, OffloadOutput.formatBody(body, args) + "\n")
        }

        val isoDate = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US).apply {
            timeZone = TimeZone.getTimeZone("UTC")
        }.format(Date())

        val body = JSONObject()
            .put("ok", true)
            .put("path", outputFile.absolutePath)
            .put("bytes", outputFile.length())
            .put("width", imageWidth)
            .put("height", imageHeight)
            .put("position", if (useFront) "front" else "back")
            .put("timestamp", isoDate)
            .toString()

        return NativeOffloadResult(0, OffloadOutput.formatBody(body, args) + "\n")
    }

    companion object {
        private const val TAG = "CameraOffload"

        private val HELP_TEXT = """
            android-camera / rovie-camera - Capture still photos with device cameras
            
            USAGE:
              android-camera <command> [options]
              
            COMMANDS:
              snap, capture    Capture a still photo to disk
              devices, list    List available camera devices
              status           Check camera permission status
              
            OPTIONS:
              --front          Use the front camera
              --back           Use the back camera (default)
              --output <path>  Target JPEG file path
              --compact        Single line JSON output
              -q, --quiet      Suppress wrapper envelope
              
            EXAMPLES:
              android-camera snap --back --output /data/data/cache/meter.jpg
              android-camera devices
              android-camera status
        """.trimIndent()
    }
}

