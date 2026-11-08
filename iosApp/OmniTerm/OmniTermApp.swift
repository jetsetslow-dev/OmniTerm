import OmniTermShared
import SwiftUI
import UIKit

@main
struct OmniTermApp: App {
    var body: some Scene {
        WindowGroup {
            // The shared screen pads itself for the safe area.
            SharedRoot().ignoresSafeArea()
        }
    }
}

/// Hosts the shared Compose screen.
private struct SharedRoot: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        MainViewControllerKt.MainViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}
