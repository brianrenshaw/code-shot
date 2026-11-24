import AppKit
import CoreText
import ImageIO
import XCTest

final class CaptureTests: XCTestCase {
    private let width = 144
    private let height = 210

    /// Each logical page row has a unique pattern. Optionally pin a header and footer
    /// to the viewport to exercise the seam separately from overlap detection.
    private func viewport(offset: Int, chrome: Bool = false, seed: Int = 7, total: Int? = nil) -> CGImage {
        let count = total ?? height
        var pixels = [UInt8]()
        for y in 0..<count {
            for x in 0..<width {
                var state = UInt32(truncatingIfNeeded: (y + offset + seed) * 21_943 + x / 8 * 9_817)
                state = (state ^ (state >> 16)) &* 0x45d9f3b
                state = (state ^ (state >> 16)) &* 0x45d9f3b
                let value = UInt8(truncatingIfNeeded: state >> 16)
                if chrome && y < 12 { pixels.append(contentsOf: [24, 46, 90, 255]) }
                else if chrome && y >= count - 14 { pixels.append(contentsOf: [152, 78, 14, 255]) }
                else { pixels.append(contentsOf: [value, 255 - value / 2, value / 2, 255]) }
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(width: width, height: count, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    private func decoded(_ image: CGImage) -> Data {
        let stride = image.width * 4
        let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                            bytesPerRow: stride, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: ctx.data!, count: stride * image.height)
    }

    func testStitchKeepsEveryRowIncludingFixedHeaderAndFooterExactlyOnce() throws {
        let stitcher = try ScrollStitcher(first: viewport(offset: 0, chrome: true))
        for offset in [1, 18, 19, 57, 132, 212] {
            XCTAssertEqual(try stitcher.add(viewport(offset: offset, chrome: true)), .added)
        }
        XCTAssertEqual(stitcher.height, height + 212)
        let expected = viewport(offset: 0, chrome: true, total: height + 212)
        XCTAssertEqual(decoded(try stitcher.result()), decoded(expected))
    }

    func testStitchesTextOnWhitePageWithoutDuplicatingBlankLines() throws {
        let width = 640, pageHeight = 830, viewportHeight = 360
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: pageHeight, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: pageHeight))
        let phrases = ["Destination folder", "Global keyboard shortcuts", "Scroll the selected pane slowly",
                       "Capture Note", "Copy Prompt to the clipboard", "Window title and browser URL"]
        for row in 0..<30 {
            let phrase = phrases[row % phrases.count] + " " + String(row)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: phrase,
                attributes: [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.black]))
            ctx.textPosition = CGPoint(x: 28 + (row % 3) * 8, y: pageHeight - 30 - row * 26)
            CTLineDraw(line, ctx)
        }
        let page = try XCTUnwrap(ctx.makeImage())
        func frame(_ offset: Int) throws -> CGImage {
            try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: offset, width: width, height: viewportHeight)))
        }
        let stitcher = try ScrollStitcher(first: frame(0))
        for offset in [29, 95, 175, 263, 371, 470] {
            XCTAssertEqual(try stitcher.add(frame(offset)), .added)
        }
        XCTAssertEqual(decoded(try stitcher.result()), decoded(page))
    }

    func testNoMovementDoesNotDuplicateImage() throws {
        let frame = viewport(offset: 0)
        let stitcher = try ScrollStitcher(first: frame)
        XCTAssertEqual(try stitcher.add(frame), .stationary)
        XCTAssertEqual(stitcher.height, height)
        XCTAssertEqual(decoded(try stitcher.result()), decoded(frame))
    }

    func testLosingOverlapAndScrollingBackRecoversFromLastGoodFrame() throws {
        let stitcher = try ScrollStitcher(first: viewport(offset: 0))
        XCTAssertEqual(try stitcher.add(viewport(offset: 400)), .lostOverlap)
        XCTAssertEqual(try stitcher.add(viewport(offset: 31)), .added)
        XCTAssertEqual(try stitcher.add(viewport(offset: 11)), .lostOverlap)
        XCTAssertEqual(stitcher.height, height + 31)
    }

    func testAutoscrollBreaksTiesInRepeatingRowsOnlyWithAnImageMatch() throws {
        func repeating(_ offset: Int, period: Int = 23) throws -> CGImage {
            let rows = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
            for y in 0..<height {
                rows.setFillColor(gray: CGFloat(((y + offset) % period) * (255 / period)) / 255, alpha: 1)
                rows.fill(CGRect(x: 0, y: height - 1 - y, width: width, height: 1))
            }
            return try XCTUnwrap(rows.makeImage())
        }
        let stitcher = try ScrollStitcher(first: repeating(0))
        let next = try repeating(30)
        XCTAssertEqual(try stitcher.add(next), .lostOverlap)
        XCTAssertEqual(try stitcher.add(next, expectedShift: 30), .added)
        XCTAssertEqual(stitcher.height, height + 30)
        XCTAssertEqual(try stitcher.add(next, expectedShift: 30), .stationary)
        XCTAssertEqual(try stitcher.add(viewport(offset: 80), expectedShift: 30), .lostOverlap)
        let bottom = try ScrollStitcher(first: repeating(0, period: 55))
        XCTAssertEqual(try bottom.add(repeating(4, period: 55), expectedShift: 30), .added)
        XCTAssertEqual(bottom.height, height + 4)
    }

    func testLimitPreservesCompletedFrames() throws {
        let stitcher = try ScrollStitcher(first: viewport(offset: 0), pixelLimit: width * (height + 30))
        XCTAssertEqual(try stitcher.add(viewport(offset: 20)), .added)
        XCTAssertEqual(try stitcher.add(viewport(offset: 40)), .limit)
        XCTAssertEqual(decoded(try stitcher.result()), decoded(viewport(offset: 0, total: height + 20)))
    }

    func testCoordinatesOnDisplayAboveAndLeftOfPrimary() {
        let region = CaptureRegion(displayID: 0, screenFrame: CGRect(x: -1440, y: 900, width: 1440, height: 900),
                                   rect: CGRect(x: -1390, y: 1600, width: 238, height: 150))
        XCTAssertEqual(region.sourceRect, CGRect(x: 50, y: 50, width: 238, height: 150))
    }

    func testSharedShortcutsUsePhysicalKeysAndStablePaletteOrder() {
        let hyper = CaptureAction.palette.initial
        let sameKey = Shortcut(key: hyper.key, modifiers: hyper.modifiers, label: "different layout")
        var assigned: [CaptureAction: Shortcut] = [.window: hyper, .areaNote: sameKey, .scrolling: .init(key: 10, modifiers: 1, label: "x")]
        XCTAssertEqual(CaptureAction.choices(for: hyper, in: assigned), [.areaNote, .window])
        assigned[.window] = nil
        XCTAssertEqual(CaptureAction.choices(for: hyper, in: assigned), [.areaNote])
        assigned[.palette] = hyper
        XCTAssertEqual(CaptureAction.choices(for: hyper, in: assigned), [.area, .areaNote, .scrolling, .scrollingNote, .window, .windowNote])
        assigned[.window] = sameKey
        assigned[.area] = hyper
        XCTAssertEqual(CaptureAction.choices(for: hyper, in: assigned), [.area, .areaNote, .window])
        XCTAssertEqual(CaptureAction.captures.map(\.rawValue), [1, 3, 2, 6, 4, 7])
        XCTAssertEqual(CaptureAction.captures.map(\.menuTitle), [
            "Capture Screen Area", "Capture Screen Area with a Note",
            "Scrolling Capture", "Scrolling Capture with a Note",
            "Capture Window", "Capture Window with a Note"
        ])
    }

    @MainActor
    func testSharedShortcutPersistsAndRestoresIndividualBindings() throws {
        let suite = "CodeShotTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // Distinct test-only hotkeys keep the running app's shortcuts available during tests.
        var original = [CaptureAction: Shortcut]()
        for (index, action) in CaptureAction.allCases.enumerated() {
            let shortcut = Shortcut(key: UInt32(82 + index), modifiers: 6912, label: "Pad" + String(index))
            defaults.set(try JSONEncoder().encode(shortcut), forKey: "shortcut." + String(action.rawValue))
            original[action] = shortcut
        }
        var first: Shortcuts? = Shortcuts(defaults: defaults)
        first?.start()
        XCTAssertEqual(first?.bindings, original)
        XCTAssertTrue(first?.assignAllToPalette() == true)
        XCTAssertEqual(first?.sharedShortcut, original[.palette])
        XCTAssertEqual(first?.bindings.values.filter { $0 == original[.palette] }.count, CaptureAction.allCases.count)
        first = nil

        let reopened = Shortcuts(defaults: defaults)
        reopened.start()
        let shared = try XCTUnwrap(reopened.sharedShortcut)
        XCTAssertEqual(CaptureAction.choices(for: shared, in: reopened.bindings), CaptureAction.captures)
        reopened.useIndividualShortcuts()
        XCTAssertNil(reopened.sharedShortcut)
        XCTAssertEqual(reopened.bindings, original)
        XCTAssertNil(defaults.data(forKey: "shortcut.shared"))
    }

    func testEveryCaptureKindHasBothClipboardAndNoteActions() {
        for kind in [CaptureKind.area, .scrolling, .window] {
            let actions = CaptureAction.captures.filter { $0.kind == kind }
            XCTAssertEqual(actions.map(\.opensNote), [false, true])
        }
        XCTAssertNil(CaptureAction.palette.kind)
        XCTAssertEqual(CaptureAction(rawValue: 3), .areaNote)
        XCTAssertEqual(Set(CaptureAction.allCases.map { $0.initial.chord }).count, CaptureAction.allCases.count)
    }

    func testCompactHeaderKeepsTheFullURLForCopying() {
        let fullURL = "http://localhost:3000/settings/account?tab=profile#email"
        let context = CaptureContext(app: "Safari", window: "Account settings", url: fullURL)
        XCTAssertEqual(context.displayURL, "localhost:3000/settings/account")
        XCTAssertEqual(context.fields.first { $0.0 == "URL" }?.1, fullURL)
        XCTAssertNil(CaptureContext().displayURL)
        XCTAssertEqual(CaptureContext(url: "file:///tmp/local%20page.html").displayURL, "/tmp/local page.html")
    }

    func testFileAndPromptRoundTripWithSpacesAndURL() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("CodeShot test " + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let frame = viewport(offset: 0)
        let file = try CaptureFiles.save(frame, in: dir)
        XCTAssertNotEqual(try CaptureFiles.save(frame, in: dir), file)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil))
        let png = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded(png), decoded(frame))
        let capture = SavedCapture(file: file, width: png.width, height: png.height,
                                   context: CaptureContext(app: "Safari", window: "Settings",
                                                           url: "https://example.test/settings"))
        XCTAssertEqual(capture.prompt(note: "  Fix padding.\nKeep the font.\n"),
                       "Fix padding.\nKeep the font.\n\nScreenshot: " + file.path +
                       "\nApp: Safari\nWindow: Settings\nURL: https://example.test/settings\nImage: 144 × 210 px")
        let plain = SavedCapture(file: file, width: 3, height: 2, context: CaptureContext())
        XCTAssertEqual(plain.prompt(note: "\n"), "Screenshot: " + file.path + "\nImage: 3 × 2 px")
    }
}
