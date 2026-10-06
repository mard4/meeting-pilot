import XCTest
@testable import MeetingPilot

final class BuiltinModelTests: XCTestCase {
    /// The app downloads these files and the pipeline (builtin_model.py) opens them by name.
    func testPipelineExpectsTheFilesTheAppDownloads() throws {
        let pythonSource = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../../../src/meeting_pilot/summarization/builtin_model.py")
            .standardizedFileURL
        let source = try String(contentsOf: pythonSource, encoding: .utf8)

        for variant in BuiltinModelVariant.allCases {
            XCTAssertTrue(
                source.contains("\"\(variant.rawValue)\": Variant(\"\(variant.fileName)\""),
                "builtin_model.py does not map \(variant.rawValue) to \(variant.fileName)"
            )
        }
    }

    func testDownloadsArePinnedToARevisionAndChecksum() {
        for variant in BuiltinModelVariant.allCases {
            let url = variant.downloadURL.absoluteString
            XCTAssertTrue(url.hasPrefix("https://huggingface.co/"), url)
            XCTAssertFalse(url.contains("/resolve/main/"), "\(variant) must download a pinned revision")
            XCTAssertTrue(url.hasSuffix("/\(variant.fileName)"), url)
            XCTAssertEqual(variant.sha256.count, 64)
            XCTAssertGreaterThan(variant.byteCount, 0)
        }
    }

    func testLightIsTheSmallerChoice() {
        XCTAssertLessThan(BuiltinModelVariant.light.byteCount, BuiltinModelVariant.quality.byteCount)
        XCTAssertLessThan(BuiltinModelVariant.light.byteCount, 1_000_000_000)
    }

    func testModelsLiveInTheAppSupportFolder() {
        XCTAssertTrue(builtinModelsDirectory().path.hasSuffix("Library/Application Support/Meeting Pilot/Models"))
        XCTAssertEqual(BuiltinModelVariant.quality.fileURL.deletingLastPathComponent(), builtinModelsDirectory())
    }
}
