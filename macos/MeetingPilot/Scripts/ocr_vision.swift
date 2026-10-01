#!/usr/bin/env swift

import AppKit
import Foundation
import Vision

struct RecognizedLine: Codable {
    let text: String
    let confidence: Float
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

guard CommandLine.arguments.count >= 2 else {
    fputs("Usage: ocr_vision.swift /path/to/image.png\n", stderr)
    exit(2)
}

let imageURL = URL(fileURLWithPath: CommandLine.arguments[1])
guard let image = NSImage(contentsOf: imageURL),
      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fputs("Could not open image: \(imageURL.path)\n", stderr)
    exit(1)
}

var lines: [RecognizedLine] = []
let request = VNRecognizeTextRequest { request, error in
    if let error = error {
        fputs("Vision OCR failed: \(error.localizedDescription)\n", stderr)
        exit(1)
    }

    let observations = request.results as? [VNRecognizedTextObservation] ?? []
    for observation in observations {
        guard let candidate = observation.topCandidates(1).first else {
            continue
        }
        let box = observation.boundingBox
        lines.append(
            RecognizedLine(
                text: candidate.string,
                confidence: candidate.confidence,
                x: box.origin.x,
                y: box.origin.y,
                width: box.size.width,
                height: box.size.height
            )
        )
    }
}

request.recognitionLevel = .accurate
request.usesLanguageCorrection = true
request.recognitionLanguages = ["it-IT", "en-US"]

let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
do {
    try handler.perform([request])
} catch {
    fputs("Vision OCR failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let data = try encoder.encode(lines)
FileHandle.standardOutput.write(data)
