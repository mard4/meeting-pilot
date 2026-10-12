import AppKit
import PDFKit
import SwiftUI
import XCTest
@testable import MeetingPilot

final class MediaImportTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("MediaImportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func date(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text) ?? Date()
    }

    func testImportedFilesAreNamedLikeRecordingsWithTheirOwnDate() {
        let name = MediaImporter.uniqueFileName(title: "Lezione 7: Integrali", date: date("2026-09-28 10:00"), fileExtension: "m4a", in: folder)
        XCTAssertEqual(name, "Meeting Pilot - 2026-09-28 10-00-00 - Lezione 7- Integrali.m4a")
    }

    func testAnExistingFileOrSidecarGetsANumberInsteadOfBeingReplaced() throws {
        let first = MediaImporter.uniqueFileName(title: "Podcast", date: date("2026-09-28 10:00"), fileExtension: "mp3", in: folder)
        try Data("audio".utf8).write(to: folder.appendingPathComponent(first))
        let second = MediaImporter.uniqueFileName(title: "Podcast", date: date("2026-09-28 10:00"), fileExtension: "mp3", in: folder)
        XCTAssertEqual(second, "Meeting Pilot - 2026-09-28 10-00-00 - Podcast 2.mp3")

        try FileManager.default.createDirectory(at: MeetingSidecar.directory(for: folder.appendingPathComponent(second)), withIntermediateDirectories: true)
        let third = MediaImporter.uniqueFileName(title: "Podcast", date: date("2026-09-28 10:00"), fileExtension: "mp3", in: folder)
        XCTAssertEqual(third, "Meeting Pilot - 2026-09-28 10-00-00 - Podcast 3.mp3")
    }

    func testImportInfoKeepsOnlyATypedTitle() {
        var draft = MediaImportDraft(
            sourceURL: URL(fileURLWithPath: "/Lezioni/Lezione 7.mp4"),
            recordedAt: date("2026-09-28 10:00"), isVideo: true, durationSeconds: 5_400
        )
        var info = MediaImporter.importInfo(for: draft)
        XCTAssertEqual(info["media_kind"] as? String, "video")
        XCTAssertEqual(info["original_path"] as? String, "/Lezioni/Lezione 7.mp4")
        XCTAssertEqual(info["recorded_at"] as? String, "2026-09-28T10:00:00")
        XCTAssertEqual(info["duration_seconds"] as? Double, 5_400)
        XCTAssertNil(info["title"])

        draft.title = "  Integrali impropri  "
        info = MediaImporter.importInfo(for: draft)
        XCTAssertEqual(info["title"] as? String, "Integrali impropri")
    }

    /// Slide text with half a surrogate pair, as PDFKit can return it, made JSONSerialization
    /// fail the whole import; the lone half becomes U+FFFD and the rest is kept.
    func testTextWithALoneSurrogateStillWritesAsJSON() throws {
        let broken = NSString(characters: [0x0041, 0xD835, 0x0042], length: 3) as String
        XCTAssertThrowsError(try JSONSerialization.data(withJSONObject: ["text": broken]))

        let safe = SlideDeck.jsonSafe(broken)
        XCTAssertEqual(safe, "A\u{FFFD}B")
        let data = try JSONSerialization.data(withJSONObject: ["text": safe])
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(decoded["text"], "A\u{FFFD}B")
        XCTAssertEqual(SlideDeck.jsonSafe("Reti neurali; π ≈ 3.14 🧠"), "Reti neurali; π ≈ 3.14 🧠")
    }

    func testImportInfoLeavesOutADurationJSONCannotHold() throws {
        let draft = MediaImportDraft(
            sourceURL: URL(fileURLWithPath: "/D/1 Intro; Training Deep NNs.mp3"),
            recordedAt: date("2026-10-09 14:00"), durationSeconds: .nan
        )
        let info = MediaImporter.importInfo(for: draft)
        XCTAssertNil(info["duration_seconds"])
        XCTAssertEqual(info["original_name"] as? String, "1 Intro; Training Deep NNs.mp3")
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: info))
    }

    func testFingerprintIdentifiesTheSameContentAndHistoryRemembersIt() throws {
        let a = folder.appendingPathComponent("a.mp3")
        let b = folder.appendingPathComponent("b.mp3")
        try Data(repeating: 7, count: 3 << 20).write(to: a)
        try Data(repeating: 7, count: 3 << 20).write(to: b)
        let fingerprint = try XCTUnwrap(MediaImportHistory.fingerprint(of: a))
        XCTAssertEqual(fingerprint, MediaImportHistory.fingerprint(of: b))

        let historyURL = folder.appendingPathComponent("imported-media.json")
        MediaImportHistory(url: historyURL).record(fingerprint)
        XCTAssertNotNil(MediaImportHistory(url: historyURL).importDate(for: fingerprint))
        XCTAssertNil(MediaImportHistory(url: historyURL).importDate(for: "other"))
    }

    /// A system sound stands in for a recording: not one of the formats copied as they
    /// are, so its audio goes through the same export as a lecture video's soundtrack.
    @MainActor
    func testImportPutsTheAudioAndItsImportSidecarInTheInbox() async throws {
        let source = URL(fileURLWithPath: "/System/Library/Sounds/Glass.aiff")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: source.path))
        let inbox = folder.appendingPathComponent("inbox")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let importer = MediaImporter(historyURL: folder.appendingPathComponent("imported-media.json"))

        var draft = await MediaImportInspector.draft(for: source, history: importer.history)
        XCTAssertNil(draft.problem)
        XCTAssertFalse(draft.isVideo)
        draft.recordedAt = date("2026-09-28 10:00")
        draft.title = "Lezione di prova"
        draft.slidesURL = try makeSlides(["Termodinamica", "Entropia"])
        importer.start([draft], options: MediaImportOptions(template: "interview", profile: .student), inbox: inbox)

        for _ in 0..<100 where !importer.jobs.isEmpty {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(importer.jobs.isEmpty, "import still running or failed: \(importer.jobs)")

        let audio = inbox.appendingPathComponent("Meeting Pilot - 2026-09-28 10-00-00 - Lezione di prova.m4a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
        let data = try Data(contentsOf: MeetingSidecar.recordingInfoURL(for: audio))
        let info = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(info["origin"] as? String, "import")
        XCTAssertEqual(info["call"] as? Bool, false)
        XCTAssertEqual(info["original_name"] as? String, "Glass.aiff")
        XCTAssertEqual(info["title"] as? String, "Lezione di prova")
        XCTAssertEqual(MeetingSidecar.readTemplateChoice(for: audio), "interview")
        XCTAssertEqual(MeetingSidecar.readProfileChoice(for: audio), .student)
        let slides = MeetingSidecar.slidesDirectory(for: audio)
        XCTAssertTrue(FileManager.default.fileExists(atPath: slides.appendingPathComponent("slides.pdf").path))
        let deck = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: slides.appendingPathComponent("slides.json"))) as? [String: Any])
        let pages = try XCTUnwrap(deck["pages"] as? [[String: Any]])
        XCTAssertEqual(pages.map { $0["text"] as? String }, ["Termodinamica", "Entropia"])

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: inbox.appendingPathComponent(".importing").path)
        XCTAssertEqual(leftovers, [])
        let fingerprint = try XCTUnwrap(MediaImportHistory.fingerprint(of: source))
        XCTAssertNotNil(importer.history.importDate(for: fingerprint))
    }

    /// Decks and notes in other formats go into the sidecar as they are, for the pipeline
    /// to read; only a PDF is read here.
    func testSlidesInOtherFormatsAreCopiedForThePipeline() throws {
        let notes = folder.appendingPathComponent("Lezione 7 - appunti.DOCX")
        try Data("not read here".utf8).write(to: notes)
        let audio = folder.appendingPathComponent("lezione.m4a")

        XCTAssertTrue(MediaImportInspector.isSlides(notes))
        XCTAssertTrue(MediaImportInspector.isSlides(URL(fileURLWithPath: "/D/deck.pptx")))
        XCTAssertTrue(MediaImportInspector.isSlides(URL(fileURLWithPath: "/D/appunti.md")))
        XCTAssertFalse(MediaImportInspector.isSlides(URL(fileURLWithPath: "/D/lezione.mp3")))
        try SlideDeck.write(notes, intoSidecarOf: audio)

        let slides = MeetingSidecar.slidesDirectory(for: audio)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: slides.path), ["slides.docx"])
    }

    /// One page per entry; `asImage` draws the text as a picture, like a scanned slide.
    private func makeSlides(_ pages: [String], asImage: Bool = false) throws -> URL {
        let url = folder.appendingPathComponent("slides-\(UUID().uuidString).pdf")
        let document = PDFDocument()
        for (index, text) in pages.enumerated() {
            let size = NSSize(width: 800, height: 450)
            let page: PDFPage?
            if asImage {
                let image = NSImage(size: size, flipped: false) { rect in
                    NSColor.white.setFill()
                    rect.fill()
                    (text as NSString).draw(at: NSPoint(x: 60, y: 200), withAttributes: [.font: NSFont.systemFont(ofSize: 48)])
                    return true
                }
                page = PDFPage(image: image)
            } else {
                let data = NSMutableData()
                var box = CGRect(origin: .zero, size: size)
                guard let consumer = CGDataConsumer(data: data as CFMutableData),
                      let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw SlideDeckError.unreadable("test") }
                context.beginPDFPage(nil)
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                (text as NSString).draw(at: NSPoint(x: 60, y: 200), withAttributes: [.font: NSFont.systemFont(ofSize: 32)])
                NSGraphicsContext.current = nil
                context.endPDFPage()
                context.closePDF()
                page = PDFDocument(data: data as Data)?.page(at: 0)
            }
            if let page { document.insert(page, at: index) }
        }
        XCTAssertTrue(document.write(to: url))
        return url
    }

    func testSlideTextIsReadPerPage() throws {
        let pdf = try makeSlides(["Termodinamica", "Ciclo di Carnot"])

        let texts = try SlideDeck.pageTexts(of: pdf)

        XCTAssertEqual(texts, ["Termodinamica", "Ciclo di Carnot"])
    }

    func testSlidesThatArePicturesAreReadWithOCR() throws {
        let pdf = try makeSlides(["Entropia e disordine"], asImage: true)

        let texts = try SlideDeck.pageTexts(of: pdf)

        XCTAssertEqual(texts.count, 1)
        XCTAssertTrue(texts[0].contains("Entropia"), "OCR read: \(texts)")
    }

    /// The Diary's slide pane: choosing a slide in the transcript shows it, and paging
    /// reports the slide now shown.
    @MainActor
    func testSlidePaneShowsTheChosenSlideAndReportsPaging() throws {
        let pdf = try makeSlides(["Uno", "Due", "Tre"])
        var shown: [Int] = []
        let pane = SlidePDFView(url: pdf, page: nil) { page, count in
            XCTAssertEqual(count, 3)
            shown.append(page)
        }
        let host = NSHostingView(rootView: pane.frame(width: 400, height: 300))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        host.layoutSubtreeIfNeeded()
        let view = try XCTUnwrap(host.descendant(of: PDFView.self))
        XCTAssertEqual(view.document?.pageCount, 3)

        host.rootView = SlidePDFView(url: pdf, page: 3) { page, _ in shown.append(page) }.frame(width: 400, height: 300)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.currentPage.flatMap { view.document?.index(for: $0) }, 2)

        view.go(to: try XCTUnwrap(view.document?.page(at: 1)))
        XCTAssertEqual(shown.last, 2)
    }

    func testDroppedSlidesGoWithTheRecordingOfTheSameName() {
        let lecture = MediaImportDraft(sourceURL: URL(fileURLWithPath: "/L/Analisi 2 - Lezione 7.mp4"), recordedAt: Date())
        let podcast = MediaImportDraft(sourceURL: URL(fileURLWithPath: "/P/Episodio 12.mp3"), recordedAt: Date())

        let named = SlideDeck.bestMatch(for: URL(fileURLWithPath: "/D/Lezione 7 - slide.pdf"), among: [podcast, lecture])
        let unnamed = SlideDeck.bestMatch(for: URL(fileURLWithPath: "/D/deck.pdf"), among: [podcast, lecture])

        XCTAssertEqual(named?.id, lecture.id)
        XCTAssertEqual(unnamed?.id, podcast.id)
        XCTAssertNil(SlideDeck.bestMatch(for: URL(fileURLWithPath: "/D/deck.pdf"), among: []))
    }

    /// A downloaded song or podcast carries only the date it reached the Mac, which says
    /// nothing about when it was recorded: the import is dated now.
    func testFilesWithoutARecordingDateAreDatedNow() async throws {
        let audio = folder.appendingPathComponent("Episodio 12.aiff")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/System/Library/Sounds/Glass.aiff"), to: audio)
        try FileManager.default.setAttributes([.creationDate: date("2025-08-21 00:56"), .modificationDate: date("2025-08-21 00:56")], ofItemAtPath: audio.path)

        let draft = await MediaImportInspector.draft(for: audio, history: MediaImportHistory(url: folder.appendingPathComponent("h.json")))

        XCTAssertNil(draft.problem)
        XCTAssertLessThan(abs(draft.recordedAt.timeIntervalSinceNow), 60)
    }

    func testFilesWithoutAudioCannotBeImported() async throws {
        let text = folder.appendingPathComponent("notes.mp3")
        try Data("not audio".utf8).write(to: text)

        let draft = await MediaImportInspector.draft(for: text, history: MediaImportHistory(url: folder.appendingPathComponent("h.json")))

        XCTAssertNotNil(draft.problem)
        XCTAssertFalse(draft.canImport)
    }
}

private extension NSView {
    func descendant<T: NSView>(of type: T.Type) -> T? {
        for subview in subviews {
            if let match = subview as? T ?? subview.descendant(of: type) { return match }
        }
        return nil
    }
}
