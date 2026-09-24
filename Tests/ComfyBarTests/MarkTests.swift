import XCTest

/// The mark is scaled and rasterised, never redrawn. These tests hold the code's
/// copy of the mark to the source SVG and to its documented geometry.
final class MarkTests: XCTestCase {
    private func svg() throws -> String {
        let b = Bundle(for: MarkTests.self)
        guard let url = b.url(forResource: "ComfyBar-2f-nest-balanced-menubar", withExtension: "svg") else {
            throw FixtureMissing(name: "ComfyBar-2f-nest-balanced-menubar.svg")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func attributes(_ svg: String) -> [(d: String, width: String)] {
        let re = try! NSRegularExpression(pattern: #"<path d="([^"]+)"[^>]*stroke-width="([0-9.]+)""#)
        let ns = svg as NSString
        return re.matches(in: svg, range: NSRange(location: 0, length: ns.length)).map {
            (ns.substring(with: $0.range(at: 1)), ns.substring(with: $0.range(at: 2)))
        }
    }

    func testPathsAreVerbatimFromSourceSVG() throws {
        let paths = attributes(try svg())
        XCTAssertEqual(paths.count, 2)
        XCTAssertEqual(paths[0].d, Mark.cPath)
        XCTAssertEqual(paths[1].d, Mark.bPath)
        XCTAssertEqual(CGFloat(Double(paths[0].width)!), Mark.cStroke)
        XCTAssertEqual(CGFloat(Double(paths[1].width)!), Mark.bStroke)
        XCTAssertTrue(try svg().contains(#"viewBox="0 0 100 100""#))
    }

    /// C = arc centre (46,50) r 38, open on the right between -38 and +38 degrees.
    func testCGeometry() {
        let bb = Mark.c.boundingBoxOfPath
        XCTAssertEqual(bb.minX, 46 - 38, accuracy: 0.05)
        XCTAssertEqual(bb.minY, 50 - 38, accuracy: 0.05)
        XCTAssertEqual(bb.maxY, 50 + 38, accuracy: 0.05)
        XCTAssertEqual(bb.maxX, 75.94, accuracy: 0.05)
        let sweep = 2 * CGFloat.pi * (360 - 76) / 360
        XCTAssertEqual(PathMetrics.length(Mark.c), 38 * sweep, accuracy: 0.1)
    }

    /// B's corners and lower bowl sit 4.10 units from the C's inner edge (the "equal margins").
    func testBEqualMargins() {
        let cInner: CGFloat = 38 - Mark.cStroke / 2          // inner edge radius of the C
        let half = Mark.bStroke / 2
        let centre = CGPoint(x: 46, y: 50)
        // stroke-outer corners of the B's spine, rounded by the round join (radius = half)
        for corner in [CGPoint(x: 36.454026695337575, y: 27), CGPoint(x: 36.454026695337575, y: 73)] {
            let gap = cInner - (hypot(corner.x - centre.x, corner.y - centre.y) + half)
            XCTAssertEqual(gap, 4.10, accuracy: 0.02, "corner \(corner)")
        }
        // lower bowl: arc centre (52.69, 60.81) r 12.19, outer edge r + half
        let bowl = CGPoint(x: 52.69, y: (48.62 + 73.0) / 2)
        let gap = cInner - (hypot(bowl.x - centre.x, bowl.y - centre.y) + 12.19 + half)
        XCTAssertEqual(gap, 4.10, accuracy: 0.02)
        let bb = Mark.b.boundingBoxOfPath
        XCTAssertEqual(bb.minY, 27, accuracy: 0.01)
        XCTAssertEqual(bb.maxY, 73, accuracy: 0.01)
        XCTAssertEqual(bb.maxX, 52.69 + 12.19, accuracy: 0.05)
    }

    func testSVGArcEndpoints() {
        // every arc must land exactly on its SVG endpoint
        var last = CGPoint.zero
        Mark.c.applyWithBlock { e in
            if e.pointee.type == .addCurveToPoint { last = e.pointee.points[2] }
        }
        XCTAssertEqual(last.x, 75.94, accuracy: 1e-9)
        XCTAssertEqual(last.y, 73.40, accuracy: 1e-9)
    }
}
