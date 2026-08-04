import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // iOS half of omniterm/screen_security. There is no FLAG_SECURE here, but the app-switcher
    // snapshot -- the real exposure on a terminal app -- can be covered. See the Swift file.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ScreenSecurityBridge") {
      ScreenSecurityBridge.register(with: registrar, window: window)
    }
  }
}
