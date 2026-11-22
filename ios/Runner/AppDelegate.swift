import Flutter
import ReplayKit
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var recordingPath: String?
  private var recordingStart = Date()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "FreeNotesRecorder") else { return }
    // Screen recording of the app with ReplayKit (iOS asks for permission), optionally with the microphone.
    let channel = FlutterMethodChannel(name: "freenotes/recorder", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      let recorder = RPScreenRecorder.shared()
      switch call.method {
      case "start":
        let args = call.arguments as? [String: Any] ?? [:]
        guard let path = args["path"] as? String else {
          result(FlutterError(code: "start", message: "Kein Dateiname", details: nil))
          return
        }
        recorder.isMicrophoneEnabled = args["audio"] as? Bool ?? false
        recorder.startRecording { error in
          DispatchQueue.main.async {
            if let error = error {
              result(FlutterError(code: "start", message: error.localizedDescription, details: nil))
            } else {
              self.recordingPath = path
              self.recordingStart = Date()
              result(nil)
            }
          }
        }
      case "stop":
        guard let path = self.recordingPath else {
          result(FlutterError(code: "stop", message: "Es läuft keine Aufnahme.", details: nil))
          return
        }
        self.recordingPath = nil
        let ms = Int(Date().timeIntervalSince(self.recordingStart) * 1000)
        try? FileManager.default.removeItem(atPath: path)
        recorder.stopRecording(withOutput: URL(fileURLWithPath: path)) { error in
          DispatchQueue.main.async {
            if let error = error {
              result(FlutterError(code: "stop", message: error.localizedDescription, details: nil))
            } else {
              result(ms)
            }
          }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
