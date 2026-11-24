// From the project root: swift Tools/GenerateIcon.swift
import AppKit

let catalog = URL(fileURLWithPath: "CodeShot/Assets.xcassets")
let folder = catalog.appendingPathComponent("AppIcon.appiconset")
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ rgb: Int) -> CGColor {
    CGColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
            green: CGFloat((rgb >> 8) & 255) / 255,
            blue: CGFloat(rgb & 255) / 255, alpha: 1)
}

func icon(pixels: Int) -> CGImage {
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                            bytesPerRow: 0, space: colorSpace,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Draw in 128-point, top-left coordinates at every resolution.
    context.translateBy(x: 0, y: CGFloat(pixels))
    let scale = CGFloat(pixels) / 128
    context.scaleBy(x: scale, y: -scale)
    let tile = CGPath(roundedRect: CGRect(x: 7.5, y: 7.5, width: 113, height: 113),
                      cornerWidth: 25, cornerHeight: 25, transform: nil)
    context.addPath(tile)
    context.clip()
    let material = CGGradient(colorsSpace: colorSpace,
                              colors: [color(0x39464A), color(0x192126), color(0x101619)] as CFArray,
                              locations: [0, 0.6, 1])!
    context.drawLinearGradient(material, start: CGPoint(x: 46, y: 5), end: CGPoint(x: 83, y: 122),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    if pixels >= 64 {
        context.addPath(tile)
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.17))
        context.setLineWidth(1.8)
        context.strokePath()
    }

    // One cut-metal corner makes both diagonally opposed capture marks.
    let corner = CGMutablePath()
    corner.move(to: CGPoint(x: 26, y: 62))
    corner.addLine(to: CGPoint(x: 26, y: 42))
    corner.addQuadCurve(to: CGPoint(x: 40, y: 28), control: CGPoint(x: 26, y: 28))
    corner.addLine(to: CGPoint(x: 69, y: 28))
    corner.addLine(to: CGPoint(x: 60, y: 38))
    corner.addLine(to: CGPoint(x: 41, y: 38))
    corner.addQuadCurve(to: CGPoint(x: 36, y: 43), control: CGPoint(x: 36, y: 38))
    corner.addLine(to: CGPoint(x: 36, y: 52))
    corner.closeSubpath()

    context.saveGState()
    context.setFillColor(color(0xFF9066))
    context.addPath(corner)
    context.fillPath()
    context.translateBy(x: 128, y: 128)
    context.scaleBy(x: -1, y: -1)
    context.setFillColor(color(0xFF754C))
    context.addPath(corner)
    context.fillPath()
    context.restoreGState()

    // The chevron and block cursor share a baseline and the corners' diagonal cuts.
    func fill(_ points: [CGPoint]) {
        context.addLines(between: points)
        context.closePath()
        context.fillPath()
    }
    context.setFillColor(color(0xFFF4DD))
    fill([CGPoint(x: 49, y: 47), CGPoint(x: 66, y: 63.5), CGPoint(x: 49, y: 80),
          CGPoint(x: 42, y: 73), CGPoint(x: 52, y: 63.5), CGPoint(x: 42, y: 54)])
    fill([CGPoint(x: 66, y: 71), CGPoint(x: 88, y: 71),
          CGPoint(x: 80, y: 80), CGPoint(x: 58, y: 80)])
    return context.makeImage()!
}

try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
let info: [String: Any] = ["author": "xcode", "version": 1]
var entries: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in 1...2 {
        let image = NSBitmapImageRep(cgImage: icon(pixels: points * scale))
        let name = "icon_\(points)x\(points)" + (scale == 2 ? "@2x" : "") + ".png"
        entries.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
        try image.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name))
    }
}
for (directory, manifest) in [(catalog, ["info": info]), (folder, ["info": info, "images": entries])] {
    let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: directory.appendingPathComponent("Contents.json"))
}
