import AppKit
import PDFKit
import Vision

enum SlideDeckError: LocalizedError {
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let name):
            return localized("Il PDF delle slide non si apre") + ": " + name
        }
    }
}

/// Slides attached to an import. The PDF and its text per page go into the sidecar as
/// `slides/slides.pdf` and `slides/slides.json`, where the pipeline places each slide
/// along the transcript (see `slides/deck.py`).
enum SlideDeck {
    static func write(_ pdf: URL, intoSidecarOf audioURL: URL) throws {
        try write(pdf, into: MeetingSidecar.slidesDirectory(for: audioURL))
    }

    /// Slides added to a meeting already processed, replacing any it had; the pipeline's
    /// `attach-slides` then takes them from the session's `sidecar/slides`.
    static func write(_ pdf: URL, intoSession sessionURL: URL) throws {
        let folder = sessionURL.appendingPathComponent("sidecar/slides", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try write(pdf, into: folder)
    }

    private static func write(_ pdf: URL, into folder: URL) throws {
        let texts = try pageTexts(of: pdf)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: pdf, to: folder.appendingPathComponent("slides.pdf"))
        let payload: [String: Any] = [
            "source_name": jsonSafe(pdf.lastPathComponent),
            "pages": texts.enumerated().map { ["page": $0.offset + 1, "text": $0.element] },
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: folder.appendingPathComponent("slides.json"), options: .atomic)
    }

    static func pageTexts(of pdf: URL) throws -> [String] {
        guard let document = PDFDocument(url: pdf) else {
            throw SlideDeckError.unreadable(pdf.lastPathComponent)
        }
        return (0..<document.pageCount).map { index in
            guard let page = document.page(at: index) else { return "" }
            let text = jsonSafe((page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
            return text.isEmpty ? recognizedText(on: page) : text
        }
    }

    /// A PDF's text layer can hold half of a UTF-16 surrogate pair (an emoji or a math
    /// symbol cut by the PDF's encoding), which `JSONSerialization` refuses to write with
    /// "The data couldn't be written because of an error in the content of the data",
    /// failing the whole import. Re-decoding replaces each lone half with U+FFFD.
    static func jsonSafe(_ text: String) -> String {
        String(decoding: Array(text.utf16), as: UTF16.self)
    }

    /// Slides scanned or exported as pictures have no text layer; Vision reads them on
    /// the Mac.
    private static func recognizedText(on page: PDFPage) -> String {
        let bounds = page.bounds(for: .mediaBox)
        let scale = 2_000 / max(bounds.width, bounds.height, 1)
        let image = page.thumbnail(of: NSSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        do {
            try VNImageRequestHandler(cgImage: cgImage).perform([request])
        } catch {
            AppLog.append("OCR slide non riuscito: \(error.localizedDescription)")
            return ""
        }
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    /// Which of the files being imported a dropped PDF belongs to: the one sharing the
    /// most words with its name ("Lezione 7.mp4" and "Lezione 7 - slide.pdf"), else the first.
    static func bestMatch(for pdf: URL, among candidates: [MediaImportDraft]) -> MediaImportDraft? {
        let words = nameWords(pdf)
        let scored = candidates.map { ($0, nameWords($0.sourceURL).intersection(words).count) }
        guard let best = scored.max(by: { $0.1 < $1.1 }) else { return nil }
        return best.1 > 0 ? best.0 : candidates.first
    }

    private static func nameWords(_ url: URL) -> Set<String> {
        Set(url.deletingPathExtension().lastPathComponent.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty })
    }
}
