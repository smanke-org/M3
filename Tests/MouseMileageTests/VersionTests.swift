import XCTest
@testable import MouseMileage

final class VersionTests: XCTestCase {
    /// Components compare as numbers, so 1.15.10 follows 1.15.9.
    func testVersionsCompareNumerically() {
        XCTAssertTrue(UpdateController.isNewer("1.15.10", than: "1.15.9"))
        XCTAssertFalse(UpdateController.isNewer("1.15.9", than: "1.15.10"))
        XCTAssertTrue(UpdateController.isNewer("1.16", than: "1.15.10"))
        XCTAssertFalse(UpdateController.isNewer("1.15.10", than: "1.15.10"))
    }
}
