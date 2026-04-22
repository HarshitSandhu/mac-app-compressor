import XCTest
@testable import Compressor

final class PathSafetyTests: XCTestCase {
    func testRejectsNonAppPath() {
        XCTAssertThrowsError(try AppSelectionService.validateAppURL(URL(fileURLWithPath: "/Applications/Foo.txt"))) { error in
            XCTAssertEqual(error as? CompressorError, .invalidAppPath("/Applications/Foo.txt"))
        }
    }

    func testRejectsSystemApplications() {
        let path = "/System/Applications/Calculator.app"
        XCTAssertThrowsError(try AppSelectionService.validateAppURL(URL(fileURLWithPath: path))) { error in
            XCTAssertEqual(error as? CompressorError, .systemAppNotAllowed(path))
        }
    }

    func testSavedSpaceCalculationNeverGoesNegative() {
        let service = DiskUsageService()

        XCTAssertEqual(service.savedBytes(original: 100, archive: 40), 60)
        XCTAssertEqual(service.savedBytes(original: 40, archive: 100), 0)
    }
}
