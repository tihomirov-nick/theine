import XCTest

/// Every `L("…")` text of the sources has an English translation in scripts/l10n/en.json with the same placeholders:
/// what make_strings.py checks when the app is built, caught already by `swift test`.
final class LocalizationTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    func testEveryTextHasATranslation() throws {
        let data = try Data(contentsOf: root.appendingPathComponent("scripts/l10n/en.json"))
        let translations = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        let keys = try sourceKeys()
        XCTAssertFalse(keys.isEmpty)
        for key in keys {
            guard let english = translations[key] else {
                XCTFail("no translation in scripts/l10n/en.json: \(key)")
                continue
            }
            XCTAssertEqual(placeholders(key), placeholders(english), "placeholders differ: \(key)")
        }
    }

    /// The keys as Swift reads them: the source form without its escapes.
    private func sourceKeys() throws -> Set<String> {
        let call = try NSRegularExpression(pattern: #"\bL\("((?:[^"\\\n]|\\.)*)""#)
        var keys = Set<String>()
        let sources = root.appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in call.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                keys.insert(text[range].replacingOccurrences(of: #"\""#, with: "\"").replacingOccurrences(of: #"\\"#, with: #"\"#))
            }
        }
        return keys
    }

    private func placeholders(_ text: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: "%[@%]")
        return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }
}
