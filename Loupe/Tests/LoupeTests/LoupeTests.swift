import XCTest
@testable import Loupe

final class LoupeTests: XCTestCase {
    func testVersionFloor() {
        XCTAssertFalse(MoleAdapter.isBelowFloor("1.53.0"))
        XCTAssertFalse(MoleAdapter.isBelowFloor("1.60.2"))
        XCTAssertTrue(MoleAdapter.isBelowFloor("1.52.9"))
        XCTAssertTrue(MoleAdapter.isBelowFloor("0.9"))
    }

    func testTreemapCoversTheRectangle() {
        let rects = Treemap.layout([6, 6, 4, 3, 2, 2, 1], in: CGRect(x: 0, y: 0, width: 400, height: 200))
        let area = rects.reduce(0.0) { $0 + $1.width * $1.height }
        XCTAssertEqual(area, 80_000, accuracy: 1)
        XCTAssertEqual(rects.count, 7)
        for r in rects { XCTAssertTrue(CGRect(x: 0, y: 0, width: 400, height: 200).insetBy(dx: -0.01, dy: -0.01).contains(r)) }
    }

    func testTrend() {
        XCTAssertEqual(Trend.of([Float?](repeating: 10, count: 40)), .flat)
        XCTAssertEqual(Trend.of((0..<40).map { Float($0) }), .up)
        XCTAssertEqual(Trend.of((0..<40).map { Float(40 - $0) }), .down)
    }

    func testFormatting() {
        XCTAssertEqual(Fmt.bytes(UInt64(9.4 * 1_073_741_824)), "9.4 GB")
        XCTAssertEqual(Fmt.watts(0.32), "320 mW")
        XCTAssertEqual(Fmt.duration(3 * 86400 + 4 * 3600), "3 days 4 h")
    }
}
