import Foundation
import XCTest

/// Payloads recorded in Step 1 (GET only on 8188; 8199 = ComfyBar's scratch test instance).
enum Fixture {
    private final class Anchor {}

    static func data(_ name: String) throws -> Data {
        let b = Bundle(for: Anchor.self)
        guard let url = b.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
                ?? b.url(forResource: name, withExtension: "json") else {
            // A missing fixture must fail, not skip - a skip would pass CI silently.
            throw FixtureMissing(name: name)
        }
        return try Data(contentsOf: url)
    }

    static func json(_ name: String) throws -> Any {
        try JSONSerialization.jsonObject(with: data(name))
    }
}

struct FixtureMissing: Error, CustomStringConvertible {
    let name: String
    var description: String { "fixture \(name) missing from the test bundle" }
}
