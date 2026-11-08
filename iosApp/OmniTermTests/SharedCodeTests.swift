import OmniTermShared
import XCTest

/// The shared Kotlin code, called from Swift inside the running app.
final class SharedCodeTests: XCTestCase {
    func testTheSharedSshConfigParserRunsOnIos() {
        let file = SshConfigParser.shared.parse(text: "Host web\n  HostName 203.0.113.10\n  User deploy\n")
        XCTAssertEqual(file.hosts.map { $0.alias }, ["web"])
        XCTAssertEqual(file.hosts.first?.hostName, "203.0.113.10")
        XCTAssertEqual(file.hosts.first?.user, "deploy")
    }

    @MainActor
    func testTheSharedScreenLoads() {
        let controller = MainViewControllerKt.MainViewController()
        controller.loadViewIfNeeded()
        XCTAssertNotNil(controller.view)
    }
}
