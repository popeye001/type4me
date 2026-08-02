import XCTest
@testable import Type4Me

final class SpeculativeLLMThrottleTests: XCTestCase {
    func testMinimumTextLength() {
        var throttle = SpeculativeLLMThrottle()

        XCTAssertEqual(throttle.submit("1234567"), .tooShort)
        XCTAssertEqual(throttle.submit("12345678"), .debounce)
    }

    func testMinimumCharacterIncrement() {
        var throttle = SpeculativeLLMThrottle()
        XCTAssertEqual(throttle.submit("12345678"), .debounce)
        XCTAssertTrue(throttle.beginDebouncedRequest(for: "12345678"))
        _ = throttle.requestCompleted(input: "12345678")

        XCTAssertEqual(throttle.submit("123456789012345"), .deltaTooSmall)
        XCTAssertEqual(throttle.submit("1234567890123456"), .debounce)
    }

    func testDebounceKeepsNewestCandidateBeforeRequestStarts() {
        var throttle = SpeculativeLLMThrottle()

        XCTAssertEqual(throttle.submit("12345678"), .debounce)
        XCTAssertEqual(throttle.submit("abcdefgh"), .debounce)

        XCTAssertFalse(throttle.beginDebouncedRequest(for: "12345678"))
        XCTAssertTrue(throttle.beginDebouncedRequest(for: "abcdefgh"))
    }

    func testDoesNotRunConcurrentRequests() {
        var throttle = SpeculativeLLMThrottle()
        _ = throttle.submit("12345678")
        XCTAssertTrue(throttle.beginDebouncedRequest(for: "12345678"))

        XCTAssertEqual(throttle.submit("1234567890123456"), .queued)
        XCTAssertFalse(throttle.beginDebouncedRequest(for: "1234567890123456"))
    }

    func testNewestPendingTranscriptIsReturnedAfterCompletion() {
        var throttle = SpeculativeLLMThrottle()
        _ = throttle.submit("12345678")
        _ = throttle.beginDebouncedRequest(for: "12345678")
        XCTAssertEqual(throttle.submit("1234567890123456"), .queued)
        XCTAssertEqual(throttle.submit("123456789012345678901234"), .queued)

        let pending = throttle.requestCompleted(input: "12345678")

        XCTAssertEqual(pending, "123456789012345678901234")
    }

    func testResetClearsInFlightAndPendingState() {
        var throttle = SpeculativeLLMThrottle()
        _ = throttle.submit("12345678")
        _ = throttle.beginDebouncedRequest(for: "12345678")
        _ = throttle.submit("1234567890123456")

        throttle.reset()

        XCTAssertFalse(throttle.inFlight)
        XCTAssertNil(throttle.pendingText)
        XCTAssertEqual(throttle.submit("12345678"), .debounce)
    }
}
