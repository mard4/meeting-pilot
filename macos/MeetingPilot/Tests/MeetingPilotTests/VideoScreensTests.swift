import CoreGraphics
import XCTest
@testable import MeetingPilot

final class VideoScreensTests: XCTestCase {
    /// 20×12 cells, as a 160-pixel-wide 16:9 frame gives.
    private let columns = 20
    private let rows = 12

    private func frame(_ time: Double, _ fill: (Int, Int) -> Float) -> VideoScreens.Frame {
        var cells: [Float] = []
        for row in 0..<rows {
            for column in 0..<columns { cells.append(fill(row, column)) }
        }
        return VideoScreens.Frame(time: time, cells: cells, contrast: 40, columns: columns)
    }

    private func screenA(_ time: Double) -> VideoScreens.Frame { frame(time) { _, column in column < 10 ? 30 : 200 } }
    private func screenB(_ time: Double) -> VideoScreens.Frame { frame(time) { row, _ in row < 6 ? 220 : 20 } }

    func testASuddenChangeStartsANewScreenAndThePictureIsItsLastStillMoment() {
        let frames = (0..<10).map { screenA(Double($0)) } + (10..<20).map { screenB(Double($0)) }
        let spans = VideoScreens.spans(of: frames, duration: 20)
        XCTAssertEqual(spans, [
            VideoScreens.Span(start: 0, end: 10, pictureTime: 9),
            VideoScreens.Span(start: 10, end: 20, pictureTime: 19),
        ])
    }

    func testATransitionTooShortToReadIsNotAScreen() {
        let fade = frame(10) { _, _ in 120 }
        let frames = (0..<10).map { screenA(Double($0)) } + [fade, frame(11) { _, _ in 60 }] + (12..<20).map { screenB(Double($0)) }
        let spans = VideoScreens.spans(of: frames, duration: 20)
        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(spans[0].end, 12, "the fade goes to the screen before it")
        XCTAssertEqual(spans[1].start, 12)
    }

    func testCodeTypedLineByLineAddsUpToANewScreen() {
        // One more row of "code" every 2 seconds: each step is small, the sum is not.
        let frames = (0..<24).map { second in frame(Double(second)) { row, _ in row < second / 2 ? 180 : 25 } }
        let spans = VideoScreens.spans(of: frames, duration: 24)
        XCTAssertGreaterThan(spans.count, 1)
        XCTAssertTrue(spans.allSatisfy { $0.end - $0.start >= VideoScreens.minScreenSeconds })
    }

    func testOnePanelChangingIsANewScreen() {
        // The bottom-right quarter only (an app's device chain), about 6% of the frame.
        let panel = (10..<20).map { second in
            frame(Double(second)) { row, column in row >= 9 && column >= 15 ? 240 : (column < 10 ? 30 : 200) }
        }
        let frames = (0..<10).map { screenA(Double($0)) } + panel
        XCTAssertLessThan(VideoScreens.difference(frames[0].cells, frames[15].cells), VideoScreens.cutShare)
        XCTAssertEqual(VideoScreens.spans(of: frames, duration: 20).count, 2)
    }

    func testAMovingCursorOrMeterIsNotANewScreen() {
        let frames = (0..<20).map { second in
            frame(Double(second)) { row, column in row == second % rows && column == 3 ? 255 : (column < 10 ? 30 : 200) }
        }
        XCTAssertEqual(VideoScreens.spans(of: frames, duration: 20).count, 1)
    }

    private func screen(_ start: Double, _ end: Double, text: String, cells: [Float]) -> VideoScreens.Screen {
        let image = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        return VideoScreens.Screen(start: start, end: end, cells: cells, columns: columns, picture: image, text: text)
    }

    func testASlideBuiltPointByPointBecomesOneScreenWithTheLastPicture() {
        let a = screenA(0).cells
        let b = screenB(0).cells
        let screens = VideoScreens.mergeRepeats([
            screen(0, 10, text: "Agenda\nInstall Node\nOpen the editor", cells: a),
            screen(10, 20, text: "Agenda\nInstall Node\nOpen the editor\nRun the extension", cells: b),
            screen(20, 30, text: "Packaging your extension for release", cells: a),
        ])
        XCTAssertEqual(screens.count, 2)
        XCTAssertEqual(screens[0].start, 0)
        XCTAssertEqual(screens[0].end, 20)
        XCTAssertTrue(screens[0].text.contains("Run the extension"))
    }

    func testTheSameScreenAfterABriefPopupIsOneScreen() {
        let a = screenA(0).cells
        let screens = VideoScreens.mergeRepeats([screen(0, 10, text: "", cells: a), screen(10, 20, text: "", cells: a)])
        XCTAssertEqual(screens.count, 1)
    }

    func testTheDeckIsWrittenAsSlidesWithTheirTimes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("VideoScreensTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try VideoScreens.write([
            screen(0, 12.34, text: "First", cells: []),
            screen(12.34, 40, text: "Second", cells: []),
        ], sourceName: "Tutorial.mp4", into: folder)

        let pages = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("slides.json"))) as? [String: Any]
        XCTAssertEqual((pages?["pages"] as? [[String: Any]])?.compactMap { $0["text"] as? String }, ["First", "Second"])
        let times = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("screens.json"))) as? [String: Any]
        XCTAssertEqual(times?["source"] as? String, "video")
        let first = (times?["screens"] as? [[String: Any]])?.first
        XCTAssertEqual(first?["page"] as? Int, 1)
        XCTAssertEqual(first?["end"] as? Double, 12.3)
        XCTAssertEqual(CGPDFDocument(folder.appendingPathComponent("slides.pdf") as CFURL)?.numberOfPages, 2)
    }

    func testOnlyVideosWithoutSlidesGetScreensAndTheyAreOnByDefault() {
        var draft = MediaImportDraft(sourceURL: URL(fileURLWithPath: "/tmp/Lesson.mp4"), recordedAt: Date(), isVideo: true)
        XCTAssertTrue(draft.capturesScreens)
        draft.slidesURL = URL(fileURLWithPath: "/tmp/Lesson.pdf")
        XCTAssertFalse(draft.capturesScreens, "the author's slides beat pictures of them")
        draft.slidesURL = nil
        draft.wantsScreens = false
        XCTAssertFalse(draft.capturesScreens)
        XCTAssertFalse(MediaImportDraft(sourceURL: URL(fileURLWithPath: "/tmp/Podcast.mp3"), recordedAt: Date()).capturesScreens)
    }
}
