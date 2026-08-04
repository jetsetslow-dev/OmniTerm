import Flutter
import UIKit

/// iOS half of `omniterm/screen_security`.
///
/// iOS has no `FLAG_SECURE`. There is no API to block a screenshot, and pretending otherwise would
/// be the worst outcome: the Settings screen would claim a protection the platform is not applying.
///
/// What iOS *does* expose is the moment the system is about to snapshot the window for the app
/// switcher — `willResignActiveNotification`. That snapshot is the real exposure on a terminal app:
/// it is taken automatically, it persists after backgrounding, and it routinely contains a live root
/// shell. Covering the window for the duration of the snapshot removes it.
///
/// So `isSupported` returns **true** — the app-switcher protection is genuinely provided — while the
/// Dart side's documentation is explicit that screenshots themselves are not blocked here. The
/// honest position is "some of it, and here is which part", not a silent no-op.
final class ScreenSecurityBridge: NSObject {
    private static let channelName = "omniterm/screen_security"

    private var secure = false
    private var cover: UIView?
    private weak var window: UIWindow?

    static func register(with registrar: FlutterPluginRegistrar, window: UIWindow?) {
        let instance = ScreenSecurityBridge()
        instance.window = window
        let channel = FlutterMethodChannel(name: channelName, binaryMessenger: registrar.messenger())
        channel.setMethodCallHandler { call, result in
            switch call.method {
            case "setSecure":
                let arguments = call.arguments as? [String: Any]
                instance.setSecure((arguments?["secure"] as? Bool) ?? false)
                result(true)
            case "isSupported":
                result(true)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
        instance.observeLifecycle()
    }

    private func observeLifecycle() {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(willResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(didBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    private func setSecure(_ enabled: Bool) {
        secure = enabled
        // Turning the setting off while the cover happens to be up must take it down, or the app
        // stays behind a blank rectangle until the next foreground.
        if !enabled { removeCover() }
    }

    @objc private func willResignActive() {
        guard secure else { return }
        guard let host = window ?? UIApplication.shared.windows.first(where: { $0.isKeyWindow }) else {
            return
        }
        guard cover == nil else { return }

        // Opaque and full-bleed: a blur would still leak the shape of the text, and on a terminal
        // the shape of the text is most of the information.
        let view = UIView(frame: host.bounds)
        view.backgroundColor = .black
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        let label = UILabel()
        label.text = "OmniTerm"
        label.textColor = UIColor(red: 0, green: 0.9, blue: 1, alpha: 1)
        label.textAlignment = .center
        label.frame = view.bounds
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(label)

        host.addSubview(view)
        cover = view
    }

    @objc private func didBecomeActive() {
        removeCover()
    }

    private func removeCover() {
        cover?.removeFromSuperview()
        cover = nil
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
