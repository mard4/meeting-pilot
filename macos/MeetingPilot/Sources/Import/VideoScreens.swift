import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// A picture of each screen an imported video shows (a slide, a window, a page of code),
/// written as a slide deck so the pipeline places it along the transcript as it does
/// slides: `slides.pdf` with one page per screen, `slides.json` with the text Vision reads
/// on each, and `screens.json` with when each one was visible (see `slides/alignment.py`).
/// A video of someone talking to the camera gets none and imports as before.
enum VideoScreens {
    /// One small frame a second is enough to see a screen change.
    static let sampleInterval = 1.0
    static let sampleWidth = 160
    /// Frames are compared in cells of this many pixels; a cell "changes" when its mean
    /// brightness moves by more than `cellThreshold` (0–255).
    static let cellSize = 8
    static let cellThreshold: Float = 14
    /// A new screen starts when this share of the cells differs from the screen's first frame.
    static let cutShare = 0.3
    /// ...or when one of `regions`×`regions` parts of the frame changes this much: in an
    /// app tutorial often only a panel changes (Ableton's device chain, a sidebar).
    static let regions = 4
    static let regionCutShare = 0.6
    /// Shorter than this is a transition, a fade or fast scrolling, not a screen.
    static let minScreenSeconds = 3.0
    static let minScreens = 3
    /// A safety net for a video that changes every few seconds for hours.
    static let maxScreens = 1000
    static let pictureWidth = 1280
    /// A face this large (share of the picture) is the speaker on camera; a webcam inset
    /// over a screen recording is usually under 0.5%.
    static let faceShare = 0.015
    /// When the speaker's face fills this share of the video, it is a talking head.
    static let talkingHeadShare = 0.6
    /// A frame this flat (standard deviation of brightness) is black or blank.
    static let minContrast: Float = 6

    struct Frame {
        let time: Double
        let cells: [Float]
        let contrast: Float
        /// Cells per row, to find each cell's region.
        var columns = 0
    }

    struct Span: Equatable {
        var start: Double
        var end: Double
        /// The last still moment, where a screen that fills up while the speaker works is complete.
        var pictureTime: Double
    }

    struct Screen {
        var start: Double
        var end: Double
        var cells: [Float]
        var columns = 0
        var picture: CGImage
        var text: String
    }

    // MARK: - Deciding what a screen is

    /// The share of cells whose brightness changed noticeably.
    static func difference(_ first: [Float], _ second: [Float]) -> Double {
        guard first.count == second.count, !first.isEmpty else { return 1 }
        let changed = zip(first, second).filter { abs($0 - $1) > cellThreshold }.count
        return Double(changed) / Double(first.count)
    }

    /// The share of changed cells in the region that changed most.
    static func regionDifference(_ first: [Float], _ second: [Float], columns: Int) -> Double {
        guard columns > 0, first.count == second.count, !first.isEmpty else { return 0 }
        let rows = first.count / columns
        var changed = [Int](repeating: 0, count: regions * regions)
        var total = [Int](repeating: 0, count: regions * regions)
        for index in first.indices {
            let region = min(index / columns * regions / max(rows, 1), regions - 1) * regions + min(index % columns * regions / columns, regions - 1)
            total[region] += 1
            if abs(first[index] - second[index]) > cellThreshold { changed[region] += 1 }
        }
        return zip(changed, total).map { $1 == 0 ? 0 : Double($0) / Double($1) }.max() ?? 0
    }

    static func isNewScreen(_ frame: Frame, comparedWith anchor: Frame, cutShare: Double) -> Bool {
        difference(frame.cells, anchor.cells) > cutShare
            || regionDifference(frame.cells, anchor.cells, columns: frame.columns) > max(regionCutShare, cutShare)
    }

    /// Screens as time spans. Each frame is compared with the first frame of its screen,
    /// not with the frame before, so slow changes (code typed line by line) add up to a
    /// new screen as surely as a sudden one. Spans too short to read go to the screen
    /// before them.
    static func spans(of frames: [Frame], duration: Double, cutShare: Double = cutShare, minSeconds: Double = minScreenSeconds) -> [Span] {
        guard let first = frames.first else { return [] }
        var spans: [Span] = []
        var anchor = first
        var start = first.time
        var previous = first.time
        for frame in frames.dropFirst() {
            if isNewScreen(frame, comparedWith: anchor, cutShare: cutShare) {
                spans.append(Span(start: start, end: frame.time, pictureTime: previous))
                anchor = frame
                start = frame.time
            }
            previous = frame.time
        }
        spans.append(Span(start: start, end: max(duration, previous), pictureTime: previous))

        var kept: [Span] = []
        for span in spans {
            if span.end - span.start >= minSeconds {
                kept.append(span)
            } else if !kept.isEmpty {
                kept[kept.count - 1].end = span.end
            } else if span == spans.last {
                kept.append(span)
            }
        }
        // A short opening span belongs to the first screen.
        if let firstKept = kept.first, firstKept.start > first.time {
            kept[0].start = first.time
        }
        return kept
    }

    /// A slide whose points appear one by one, or the same screen shown again after a
    /// brief popup, becomes one screen: the later picture, the whole time.
    static func mergeRepeats(_ screens: [Screen]) -> [Screen] {
        var merged: [Screen] = []
        for screen in screens {
            if let last = merged.last, isContinuation(of: last, by: screen) {
                var combined = screen
                combined.start = last.start
                merged[merged.count - 1] = combined
            } else {
                merged.append(screen)
            }
        }
        return merged
    }

    static func isContinuation(of earlier: Screen, by later: Screen) -> Bool {
        // Nearly the same picture everywhere: one panel changing is a new screen.
        if difference(earlier.cells, later.cells) < cutShare / 2,
           regionDifference(earlier.cells, later.cells, columns: later.columns) < regionCutShare / 2 { return true }
        let before = words(in: earlier.text)
        let after = words(in: later.text)
        guard before.count >= 3, after.count > before.count else { return false }
        return Double(before.intersection(after).count) / Double(before.count) >= 0.9
    }

    static func words(in text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.filter { $0.count >= 2 }.map(String.init))
    }

    // MARK: - Reading the video

    /// Writes the deck into `folder` and returns how many screens it has; 0 when the
    /// video shows none worth keeping, and then nothing is written. `knownDuration` caps the
    /// video's own: AVFoundation reads YouTube's video-only streams (fragmented MP4) as
    /// twice as long as they are, with the frames at the right times and nothing after.
    @discardableResult
    static func capture(
        from video: URL,
        into folder: URL,
        knownDuration: Double? = nil,
        progress: @escaping (Double) async -> Void = { _ in }
    ) async throws -> Int {
        let asset = AVURLAsset(url: video)
        guard try await !asset.loadTracks(withMediaType: .video).isEmpty else { return 0 }
        var duration = try await asset.load(.duration).seconds
        if let knownDuration, knownDuration.isFinite, knownDuration > 0 {
            duration = min(duration, knownDuration)
        }
        guard duration.isFinite, duration > minScreenSeconds * Double(minScreens) else { return 0 }

        let frames = try await sample(asset, duration: duration) { await progress($0 * 0.7) }
        var cut = cutShare
        var spans = self.spans(of: frames, duration: duration, cutShare: cut)
        while spans.count > maxScreens, cut < 0.95 {
            cut = min(cut * 1.3, 0.95)
            spans = self.spans(of: frames, duration: duration, cutShare: cut)
        }
        guard spans.count >= minScreens else { return 0 }

        let pictures = AVAssetImageGenerator(asset: asset)
        pictures.appliesPreferredTrackTransform = true
        pictures.maximumSize = CGSize(width: pictureWidth, height: pictureWidth)
        pictures.requestedTimeToleranceBefore = CMTime(seconds: 0.3, preferredTimescale: 600)
        pictures.requestedTimeToleranceAfter = CMTime(seconds: 0.3, preferredTimescale: 600)

        var screens: [Screen] = []
        var faceSeconds = 0.0
        for (index, span) in spans.enumerated() {
            await progress(0.7 + 0.3 * Double(index) / Double(spans.count))
            let frame = frames.min { abs($0.time - span.pictureTime) < abs($1.time - span.pictureTime) }
            if let frame, frame.contrast < minContrast { continue }
            guard let picture = try? await pictures.image(at: CMTime(seconds: span.pictureTime, preferredTimescale: 600)).image else { continue }
            if largestFaceShare(in: picture) > faceShare {
                faceSeconds += span.end - span.start
                continue
            }
            screens.append(Screen(
                start: span.start, end: span.end, cells: frame?.cells ?? [], columns: frame?.columns ?? 0,
                picture: picture, text: recognizedText(in: picture)
            ))
        }
        guard faceSeconds / duration < talkingHeadShare else { return 0 }
        screens = mergeRepeats(screens)
        guard screens.count >= minScreens else { return 0 }
        // Time no screen claimed (the speaker's face in between) goes to the screen before it.
        for index in screens.indices.dropLast() {
            screens[index].end = screens[index + 1].start
        }
        screens[0].start = 0
        // The speaker talking to the camera after the last screen still belongs somewhere.
        screens[screens.count - 1].end = max(screens[screens.count - 1].end, duration)

        try write(screens, sourceName: video.lastPathComponent, into: folder)
        await progress(1)
        return screens.count
    }

    private static func sample(_ asset: AVAsset, duration: Double, progress: @escaping (Double) async -> Void) async throws -> [Frame] {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: sampleWidth, height: sampleWidth)
        // Any frame near the second will do: decoding is the slow part.
        generator.requestedTimeToleranceBefore = CMTime(seconds: sampleInterval / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: sampleInterval / 2, preferredTimescale: 600)
        let times = stride(from: 0.0, to: duration, by: sampleInterval).map { CMTime(seconds: $0, preferredTimescale: 600) }
        var frames: [Frame] = []
        frames.reserveCapacity(times.count)
        for await result in generator.images(for: times) {
            if case .success(let requested, let image, _) = result, let frame = cells(of: image, at: requested.seconds) {
                frames.append(frame)
                if frames.count % 30 == 0 { await progress(Double(frames.count) / Double(times.count)) }
            }
        }
        return frames.sorted { $0.time < $1.time }
    }

    /// The frame in grey at `sampleWidth`, averaged per cell.
    static func cells(of image: CGImage, at time: Double) -> Frame? {
        let width = sampleWidth
        let height = max(cellSize, Int((Double(image.height) / Double(image.width) * Double(width)).rounded()))
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        let columns = width / cellSize
        let rows = height / cellSize
        var cells = [Float](repeating: 0, count: columns * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                var sum = 0
                for y in row * cellSize..<(row + 1) * cellSize {
                    for x in column * cellSize..<(column + 1) * cellSize {
                        sum += Int(pixels[y * width + x])
                    }
                }
                cells[row * columns + column] = Float(sum) / Float(cellSize * cellSize)
            }
        }
        let mean = pixels.reduce(0) { $0 + Int($1) }
        let average = Float(mean) / Float(pixels.count)
        let variance = pixels.reduce(Float(0)) { $0 + pow(Float($1) - average, 2) } / Float(pixels.count)
        return Frame(time: time, cells: cells, contrast: variance.squareRoot(), columns: columns)
    }

    private static func largestFaceShare(in picture: CGImage) -> Double {
        let request = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: picture).perform([request])
        return (request.results ?? []).map { Double($0.boundingBox.width * $0.boundingBox.height) }.max() ?? 0
    }

    private static func recognizedText(in picture: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try? VNImageRequestHandler(cgImage: picture).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return SlideDeck.jsonSafe(lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Writing the deck

    static let timesName = "screens.json"

    /// The same files `SlideDeck` writes for a PDF, plus the times. Each page is the JPEG
    /// itself (drawn from JPEG data, Quartz embeds it without re-encoding), so a long video
    /// stays a reasonable size.
    static func write(_ screens: [Screen], sourceName: String, into folder: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let pdf = folder.appendingPathComponent("slides.pdf")
        guard let context = CGContext(pdf as CFURL, mediaBox: nil, nil) else { throw CocoaError(.fileWriteUnknown) }
        for screen in screens {
            let image = jpegBacked(screen.picture) ?? screen.picture
            var box = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            context.beginPage(mediaBox: &box)
            context.draw(image, in: box)
            context.endPage()
        }
        context.closePDF()

        let pages = screens.enumerated().map { ["page": $0.offset + 1, "text": $0.element.text] as [String: Any] }
        let texts: [String: Any] = ["source_name": SlideDeck.jsonSafe(sourceName), "pages": pages]
        try JSONSerialization.data(withJSONObject: texts, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("slides.json"), options: .atomic)
        let times: [String: Any] = [
            "source": "video",
            "screens": screens.enumerated().map {
                ["page": $0.offset + 1, "start": round($0.element.start * 10) / 10, "end": round($0.element.end * 10) / 10]
            },
        ]
        try JSONSerialization.data(withJSONObject: times, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent(timesName), options: .atomic)
    }

    private static func jpegBacked(_ image: CGImage) -> CGImage? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
        guard CGImageDestinationFinalize(destination),
              let source = CGImageSourceCreateWithData(data, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
