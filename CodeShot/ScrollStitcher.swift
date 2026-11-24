import Accelerate
import CoreGraphics
import Foundation

/// Matches downward motion in the interior of the viewport. Each match replaces the old
/// footer with the latest frame's tail, leaving fixed browser chrome only at the ends.
final class ScrollStitcher {
    enum Update: Equatable { case added, stationary, lostOverlap, limit }
    private let pixelLimit: Int
    private var previous: CGImage
    private var sample: RowSample
    private var bands: [CGImage] = []
    private var tailStart = 0
    private(set) var height: Int

    init(first: CGImage, pixelLimit: Int = 24_000_000) throws {
        guard first.height >= 64, first.width >= 32 else {
            throw CaptureError("Select a larger area for a scrolling capture.")
        }
        guard first.width <= pixelLimit / first.height else {
            throw CaptureError("Select a smaller area for a scrolling capture.")
        }
        self.pixelLimit = pixelLimit
        previous = first
        sample = try RowSample(image: first)
        height = first.height
    }

    func add(_ image: CGImage, expectedShift: Int? = nil) throws -> Update {
        guard image.width == previous.width, image.height == previous.height else {
            throw CaptureError("The display size changed during capture.")
        }
        let next = try RowSample(image: image)
        guard let shift = sample.displacement(to: next, expectedShift: expectedShift) else { return .lostOverlap }
        guard shift > 0 else { return .stationary }
        guard height + shift <= min(30_000, pixelLimit / image.width) else { return .limit }

        let seam = previous.height * 4 / 5
        let rect = CGRect(x: 0, y: tailStart, width: image.width, height: seam - tailStart)
        guard let crop = previous.cropping(to: rect) else { throw CaptureError("Couldn’t join these frames.") }
        // A CGImage crop can retain the entire source frame. Materialize just the band.
        let ctx = try Self.bitmap(width: crop.width, height: crop.height)
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        guard let band = ctx.makeImage() else { throw CaptureError("Couldn’t store the next strip.") }
        bands.append(band)
        tailStart = seam - shift
        previous = image
        sample = next
        height += shift
        return .added
    }

    func result() throws -> CGImage {
        guard !bands.isEmpty else { return previous }
        let ctx = try Self.bitmap(width: previous.width, height: height)
        var y = height
        for band in bands {
            y -= band.height
            ctx.draw(band, in: CGRect(x: 0, y: y, width: band.width, height: band.height))
        }
        guard let tail = previous.cropping(to: CGRect(x: 0, y: tailStart, width: previous.width,
                                                       height: previous.height - tailStart)) else {
            throw CaptureError("Couldn’t finish the last frame.")
        }
        ctx.draw(tail, in: CGRect(x: 0, y: 0, width: tail.width, height: tail.height))
        guard let image = ctx.makeImage() else { throw CaptureError("Couldn’t finish the scrolling image.") }
        return image
    }

    private static func bitmap(width: Int, height: Int) throws -> CGContext {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw CaptureError("There isn’t enough memory for this capture.")
        }
        return ctx
    }
}

private struct RowSample {
    static let columns = 32
    let rows: [Float]
    let height: Int

    init(image: CGImage) throws {
        height = image.height
        let width = Self.columns
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = ctx.data else { throw CaptureError("Couldn’t compare the scrolling frames.") }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height)
        rows = bytes.map(Float.init)
    }

    func displacement(to new: RowSample, expectedShift: Int?) -> Int? {
        if rows == new.rows { return 0 }
        let width = Self.columns
        // Ignore the sides (scrollbars), the header, and the footer. Prefer rows with vertical
        // detail so a large white margin or several blank paragraphs cannot dominate the score.
        let first = max(3, height / 8)
        let end = height * 4 / 5
        let binSize = max(1, (end - first) / 64)
        return rows.withUnsafeBufferPointer { oldRows in
            new.rows.withUnsafeBufferPointer { newRows -> Int? in
                let old = oldRows.baseAddress!
                let fresh = newRows.baseAddress!
                func difference(_ a: UnsafePointer<Float>, _ b: UnsafePointer<Float>) -> Float {
                    var sum: Float = 0
                    vDSP_distancesq(a + 2, 1, b + 2, 1, &sum, vDSP_Length(width - 4))
                    return sum / Float(width - 4)
                }
                var anchors: [Int] = []
                for bin in stride(from: first, to: end, by: binSize) {
                    var best = bin
                    var detail: Float = 2
                    for y in bin..<min(end, bin + binSize) {
                        let d = difference(fresh + y * width, fresh + (y - 3) * width)
                        if d > detail { best = y; detail = d }
                    }
                    if detail > 2 { anchors.append(best) }
                }
                guard anchors.count >= 4 else { return nil }
                let maxShift = height / 2
                var scores = [Float](repeating: .infinity, count: maxShift + 1)
                for shift in 0...maxShift {
                    var sum: Float = 0
                    var count = 0
                    for y in anchors {
                        if y + shift >= end { break }
                        sum += min(900, difference(fresh + y * width, old + (y + shift) * width))
                        count += 1
                    }
                    if count >= max(4, anchors.count / 5) { scores[shift] = sum / Float(count) }
                }
                guard let best = scores.indices.min(by: { scores[$0] < scores[$1] }), scores[best] < 42 else {
                    return nil
                }
                // Repeated patterns can produce equally convincing but different page lengths.
                let rival = scores.indices.filter { abs($0 - best) > 1 }.map { scores[$0] }.min() ?? .infinity
                if rival > scores[best] * 1.4 + 1 { return best }
                // With repeated rows, the wheel distance can break a visual tie. Still require
                // a close pixel match. Blank or unrelated frames cannot advance the capture.
                guard let expectedShift, expectedShift > 0, expectedShift <= maxShift else { return nil }
                let tolerance = min(42, scores[best] * 1.4 + 1)
                let near = max(1, expectedShift - 2)...min(maxShift, expectedShift + 2)
                if let guided = near.min(by: { scores[$0] < scores[$1] }), scores[guided] <= tolerance {
                    return guided
                }
                // The last input can be clamped by the bottom of a pane. Prefer a shorter
                // match only if it's the sole convincing displacement within one wheel step.
                let possible = 0...min(maxShift, expectedShift + 2)
                guard let shorter = possible.min(by: { scores[$0] < scores[$1] }),
                      scores[shorter] <= tolerance,
                      !possible.contains(where: { abs($0 - shorter) > 1 && scores[$0] <= tolerance })
                else { return nil }
                return shorter
            }
        }
    }
}

actor ScrollFrames {
    private let stitcher: ScrollStitcher
    init(first: CGImage) throws { stitcher = try ScrollStitcher(first: first) }
    func add(_ frame: CGImage, expectedShift: Int?) throws -> (ScrollStitcher.Update, Int) {
        let change = try stitcher.add(frame, expectedShift: expectedShift)
        return (change, stitcher.height)
    }
    func result() throws -> CGImage { try stitcher.result() }
}
