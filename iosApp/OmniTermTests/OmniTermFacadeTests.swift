import XCTest
import OmniTermShared

final class OmniTermFacadeTests: XCTestCase {
    func testObservationAndCancellationAreExplicit() {
        let facade = OmniTermFacade()
        var snapshots: [SwiftShellSnapshot] = []
        let observation = facade.observe { snapshots.append($0) }
        XCTAssertEqual(snapshots.last?.title, "OmniTerm")
        observation.cancel()
        facade.retry()
        XCTAssertEqual(snapshots.count, 1)
    }
}
