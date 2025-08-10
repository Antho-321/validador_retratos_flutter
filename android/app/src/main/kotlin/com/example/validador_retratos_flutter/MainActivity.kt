package com.example.validador_retratos_flutter

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CameraCharacteristics
import android.content.Context

class MainActivity: FlutterActivity() {
    private val CAMERA_CHANNEL = "posture_camera/config"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CAMERA_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setMirrorMode" -> {
                        val enable = call.argument<Boolean>("enable") ?: true
                        val cameraId = call.argument<String>("cameraId")
                        
                        try {
                            configureCameraMirroring(cameraId, enable)
                            result.success("Camera mirroring configured")
                        } catch (e: Exception) {
                            result.error("CAMERA_ERROR", "Failed to configure camera", e.message)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
    
    private fun configureCameraMirroring(cameraId: String?, enable: Boolean) {
        val cameraManager = getSystemService(Context.CAMERA_SERVICE) as CameraManager
        
        cameraId?.let { id ->
            val characteristics = cameraManager.getCameraCharacteristics(id)
            val facing = characteristics.get(CameraCharacteristics.LENS_FACING)
            
            if (facing == CameraCharacteristics.LENS_FACING_FRONT) {
                // Configure front camera mirroring
                // Note: This is a simplified example. Real implementation would
                // need to interact with camera2 API or camera plugin internals
                println("Configuring front camera mirroring: $enable")
            }
        }
    }
}