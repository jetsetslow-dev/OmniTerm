import Flutter
import UIKit

/// iOS launcher quick actions and their cold/warm-launch delivery to Dart.
final class PlatformIntegrationBridge: NSObject, FlutterStreamHandler {
  static let shared = PlatformIntegrationBridge()

  private var eventSink: FlutterEventSink?
  private var pending: [[String: Any]] = []

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = PlatformIntegrationBridge.shared
    FlutterMethodChannel(
      name: "omniterm/shortcuts",
      binaryMessenger: registrar.messenger()
    ).setMethodCallHandler(instance.handleShortcutMethod)

    FlutterMethodChannel(
      name: "omniterm/external_launch",
      binaryMessenger: registrar.messenger()
    ).setMethodCallHandler(instance.handleExternalMethod)

    FlutterEventChannel(
      name: "omniterm/external_launch/events",
      binaryMessenger: registrar.messenger()
    ).setStreamHandler(instance)
  }

  func capture(_ shortcut: UIApplicationShortcutItem, coldStart: Bool) {
    guard let action = decode(shortcut) else { return }
    if coldStart || eventSink == nil {
      pending.append(action)
    } else {
      eventSink?(action)
    }
  }

  private func handleExternalMethod(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "takeInitialActions" else {
      result(FlutterMethodNotImplemented)
      return
    }
    let actions = pending
    pending.removeAll()
    result(actions)
  }

  private func handleShortcutMethod(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "pinServer":
      // iOS has no pin-confirmation API; a dynamic shortcut is the native equivalent.
      upsert(serverItem(args), result: result)
    case "pushServer":
      upsert(serverItem(args), result: result)
    case "reportServerUsed":
      let id = (args["id"] as? NSNumber)?.intValue ?? -1
      let existing = UIApplication.shared.shortcutItems?.first {
        $0.type == "omniterm.connect" && ($0.userInfo?["id"] as? NSNumber)?.intValue == id
      }
      guard let item = existing else { result(false); return }
      upsert(item, result: result)
    case "pushSplit":
      let first = (args["firstId"] as? NSNumber)?.intValue ?? -1
      let second = (args["secondId"] as? NSNumber)?.intValue ?? -1
      guard first >= 0, second >= 0 else { result(false); return }
      let title = "\(args["firstName"] as? String ?? "Host") + \(args["secondName"] as? String ?? "Host")"
      upsert(
        UIApplicationShortcutItem(
          type: "omniterm.split",
          localizedTitle: title,
          localizedSubtitle: "Open split terminal",
          icon: UIApplicationShortcutIcon(systemImageName: "rectangle.split.2x1"),
          userInfo: ["firstId": first as NSNumber, "secondId": second as NSNumber]
        ),
        result: result
      )
    case "pushShare":
      let id = (args["id"] as? NSNumber)?.intValue ?? -1
      guard id >= 0 else { result(false); return }
      upsert(
        UIApplicationShortcutItem(
          type: "omniterm.share",
          localizedTitle: args["name"] as? String ?? "Network share",
          localizedSubtitle: args["address"] as? String,
          icon: UIApplicationShortcutIcon(systemImageName: "externaldrive.connected.to.line.below"),
          userInfo: ["id": id as NSNumber]
        ),
        result: result
      )
    case "removeServer":
      remove(type: "omniterm.connect", id: (args["id"] as? NSNumber)?.intValue, result: result)
    case "removeShare":
      remove(type: "omniterm.share", id: (args["id"] as? NSNumber)?.intValue, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func serverItem(_ args: [String: Any]) -> UIApplicationShortcutItem {
    let id = (args["id"] as? NSNumber)?.intValue ?? -1
    return UIApplicationShortcutItem(
      type: "omniterm.connect",
      localizedTitle: args["name"] as? String ?? "Host",
      localizedSubtitle: args["host"] as? String,
      icon: UIApplicationShortcutIcon(systemImageName: "terminal"),
      userInfo: ["id": id as NSNumber]
    )
  }

  private func upsert(_ item: UIApplicationShortcutItem, result: @escaping FlutterResult) {
    let identity = shortcutIdentity(item)
    var items = UIApplication.shared.shortcutItems ?? []
    items.removeAll { candidate in
      candidate.type == item.type && shortcutIdentity(candidate) == identity
    }
    items.insert(item, at: 0)
    UIApplication.shared.shortcutItems = Array(items.prefix(4))
    result(true)
  }

  private func shortcutIdentity(_ item: UIApplicationShortcutItem) -> String {
    let id = (item.userInfo?["id"] as? NSNumber)?.stringValue ?? ""
    let first = (item.userInfo?["firstId"] as? NSNumber)?.stringValue ?? ""
    let second = (item.userInfo?["secondId"] as? NSNumber)?.stringValue ?? ""
    return "\(item.type):\(id):\(first):\(second)"
  }

  private func remove(type: String, id: Int?, result: @escaping FlutterResult) {
    UIApplication.shared.shortcutItems = (UIApplication.shared.shortcutItems ?? []).filter { item in
      guard item.type == type else { return true }
      return (item.userInfo?["id"] as? NSNumber)?.intValue != id
    }
    result(true)
  }

  private func decode(_ item: UIApplicationShortcutItem) -> [String: Any]? {
    let sequence = UUID().uuidString
    switch item.type {
    case "omniterm.connect":
      guard let id = (item.userInfo?["id"] as? NSNumber)?.intValue else { return nil }
      return ["id": sequence, "type": "connect_server", "targetId": id]
    case "omniterm.split":
      guard
        let first = (item.userInfo?["firstId"] as? NSNumber)?.intValue,
        let second = (item.userInfo?["secondId"] as? NSNumber)?.intValue
      else { return nil }
      return ["id": sequence, "type": "open_split", "targetId": first, "secondId": second]
    case "omniterm.share":
      guard let id = (item.userInfo?["id"] as? NSNumber)?.intValue else { return nil }
      return ["id": sequence, "type": "open_share", "targetId": id]
    case "omniterm.add_server":
      return ["id": sequence, "type": "add_server"]
    case "omniterm.open_sftp":
      return ["id": sequence, "type": "open_sftp"]
    case "omniterm.open_network":
      return ["id": sequence, "type": "open_network"]
    default:
      return nil
    }
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }
}
