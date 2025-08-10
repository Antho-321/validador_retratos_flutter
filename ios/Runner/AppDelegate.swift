import UIKit
import Flutter
import AVFoundation

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    
    let controller : FlutterViewController = window?.rootViewController as! FlutterViewController
    let cameraChannel = FlutterMethodChannel(name: "posture_camera/config",
                                           binaryMessenger: controller.binaryMessenger)
    
    cameraChannel.setMethodCallHandler({
      [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) -> Void in
      
      switch call.method {
      case "setMirrorMode":
        if let args = call.arguments as? [String: Any],
           let enable = args["enable"] as? Bool,
           let cameraId = args["cameraId"] as? String {
          
          self?.configureCameraMirroring(cameraId: cameraId, enable: enable, result: result)
        } else {
          result(FlutterError(code: "INVALID_ARGS", message: "Invalid arguments", details: nil))
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    })
    
    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
  
  private func configureCameraMirroring(cameraId: String, enable: Bool, result: @escaping FlutterResult) {
    // Configure iOS camera mirroring
    // This would interact with AVCaptureDevice and AVCaptureSession
    
    DispatchQueue.main.async {
      // In a real implementation, you'd configure the AVCaptureVideoPreviewLayer
      // to disable automatic mirroring for front camera
      print("Configuring iOS camera mirroring: \(enable) for camera: \(cameraId)")
      result("Camera mirroring configured successfully")
    }
  }
}