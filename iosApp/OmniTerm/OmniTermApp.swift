import SwiftUI
import OmniTermShared

@main
struct OmniTermApp: App {
    private let facade = OmniTermFacade()

    var body: some Scene {
        WindowGroup {
            SharedRoot(facade: facade)
                .ignoresSafeArea(.keyboard)
        }
    }
}

private struct SharedRoot: UIViewControllerRepresentable {
    let facade: OmniTermFacade

    func makeUIViewController(context: Context) -> UIViewController {
        MainViewControllerKt.MainViewController(facade: facade)
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}
