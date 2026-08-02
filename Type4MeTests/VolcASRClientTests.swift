import XCTest
@testable import Type4Me

final class VolcASRClientTests: XCTestCase {
    func testWebSocketUpgradeProbeMessageIsIgnored() {
        let message = #"Bad Request("error", "cannot upgrade to websocket: websocket: the client is not using the websocket protocol: 'upgrade' token not found in 'Connection' header")"#

        XCTAssertTrue(VolcASRError.isWebSocketUpgradeProbeMessage(message))
    }

    func testNormalVendorErrorIsNotIgnored() {
        XCTAssertFalse(VolcASRError.isWebSocketUpgradeProbeMessage("invalid access key"))
    }
}
