#!/usr/bin/env swift
import AppKit
import CoreGraphics
import Foundation

// MARK: - Dimensions & Scaling
let width: CGFloat = 660
let height: CGFloat = 400
let scale: CGFloat = 2.0 // Retina 2x

let pixelWidth = Int(width * scale)
let pixelHeight = Int(height * scale)

let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let context = CGContext(
    data: nil,
    width: pixelWidth,
    height: pixelHeight,
    bitsPerComponent: 8,
    bytesPerRow: pixelWidth * 4,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fatalError("Failed to create CGContext")
}

let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
NSGraphicsContext.current = nsContext
context.scaleBy(x: scale, y: scale)

// MARK: - Ordal Brand Colors
// Ordal Jade: #0D7F62 (13, 127, 98)
let ordalJade = NSColor(red: 13.0 / 255.0, green: 127.0 / 255.0, blue: 98.0 / 255.0, alpha: 1.0)
// Ordal Ink: #15171C (21, 23, 28)
let ordalInk = NSColor(red: 21.0 / 255.0, green: 23.0 / 255.0, blue: 28.0 / 255.0, alpha: 1.0)
// Subtle Jade tint
let jadeTint = NSColor(red: 13.0 / 255.0, green: 127.0 / 255.0, blue: 98.0 / 255.0, alpha: 0.08)
let jadeTintStroke = NSColor(red: 13.0 / 255.0, green: 127.0 / 255.0, blue: 98.0 / 255.0, alpha: 0.35)

// 1. Background Gradient (clean, modern canvas)
let bgGradient = NSGradient(
    starting: NSColor(red: 0.985, green: 0.992, blue: 0.995, alpha: 1.0),
    ending: NSColor(red: 0.935, green: 0.952, blue: 0.960, alpha: 1.0)
)!
bgGradient.draw(in: CGRect(x: 0, y: 0, width: width, height: height), angle: 270)

// 2. Subtle Organic Wave Banner at the top with Ordal Jade tint
let bannerPath = NSBezierPath()
bannerPath.move(to: CGPoint(x: 0, y: height))
bannerPath.line(to: CGPoint(x: width, y: height))
bannerPath.line(to: CGPoint(x: width, y: height - 105))
bannerPath.curve(
    to: CGPoint(x: 0, y: height - 105),
    controlPoint1: CGPoint(x: width * 0.72, y: height - 128),
    controlPoint2: CGPoint(x: width * 0.28, y: height - 85)
)
bannerPath.close()
jadeTint.setFill()
bannerPath.fill()

// 3. Header: Logo Badge & Typography
let titleFont = NSFont.systemFont(ofSize: 22, weight: .bold)
let subtitleFont = NSFont.systemFont(ofSize: 13, weight: .regular)

let titleAttributes: [NSAttributedString.Key: Any] = [
    .font: titleFont,
    .foregroundColor: ordalInk
]
let subtitleAttributes: [NSAttributedString.Key: Any] = [
    .font: subtitleFont,
    .foregroundColor: NSColor(red: 0.40, green: 0.45, blue: 0.52, alpha: 1.0)
]

let iconSize: CGFloat = 40
let iconRect = CGRect(x: 52, y: height - 76, width: iconSize, height: iconSize)

// Draw app icon if available, otherwise draw branded tile
let scriptDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().path
let rootDir = (scriptDir as NSString).deletingLastPathComponent
let iconCandidates = [
    rootDir + "/assets/brand/ordal-app-icon-512.png",
    rootDir + "/assets/brand/ordal-macos-icon-1024.png",
    "assets/brand/ordal-app-icon-512.png"
]

var iconDrawn = false
for path in iconCandidates {
    if let image = NSImage(contentsOfFile: path) {
        let iconBgPath = NSBezierPath(roundedRect: iconRect, xRadius: 10, yRadius: 10)
        NSGraphicsContext.saveGraphicsState()
        iconBgPath.addClip()
        image.draw(in: iconRect)
        NSGraphicsContext.restoreGraphicsState()
        iconDrawn = true
        break
    }
}

if !iconDrawn {
    let iconBgPath = NSBezierPath(roundedRect: iconRect, xRadius: 10, yRadius: 10)
    ordalJade.setFill()
    iconBgPath.fill()
}

let titleStr = NSAttributedString(string: "Ordal", attributes: titleAttributes)
titleStr.draw(at: CGPoint(x: 104, y: height - 58))

let subtitleStr = NSAttributedString(
    string: "To install Ordal, drag the app into your Applications folder.",
    attributes: subtitleAttributes
)
subtitleStr.draw(at: CGPoint(x: 104, y: height - 78))

// 4. Target Alignment Centers (Matches Finder coordinate (x: 175, y: 195) and (x: 485, y: 195))
// Finder icon center is Y = 195. Icon image (110x110) spans Y 140..250.
// Text label is drawn below the icon by Finder, spanning Y 252..272.
// The composite (icon + text) center in Finder is Y = 206 -> Cocoa Y = 400 - 206 = 194.
let iconCenter = CGPoint(x: 175, y: 205)
let appDropCenter = CGPoint(x: 485, y: 205)
let cardCenterY: CGFloat = 194
let cardWidth: CGFloat = 156
let cardHeight: CGFloat = 176
let cardRadius: CGFloat = 26

// Left Card: Subtle Drop Card for Ordal.app (comfortably encloses both icon & text label)
let appBoxRect = CGRect(
    x: iconCenter.x - cardWidth / 2,
    y: cardCenterY - cardHeight / 2,
    width: cardWidth,
    height: cardHeight
)
let appBoxPath = NSBezierPath(roundedRect: appBoxRect, xRadius: cardRadius, yRadius: cardRadius)
NSColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.85).setFill()
appBoxPath.fill()
NSColor(red: 0.85, green: 0.90, blue: 0.92, alpha: 0.9).setStroke()
appBoxPath.lineWidth = 1.5
appBoxPath.stroke()

// Right Box: Dashed Container for Applications Folder
let targetRect = CGRect(
    x: appDropCenter.x - cardWidth / 2,
    y: cardCenterY - cardHeight / 2,
    width: cardWidth,
    height: cardHeight
)
let targetPath = NSBezierPath(roundedRect: targetRect, xRadius: cardRadius, yRadius: cardRadius)
NSColor(red: 0.94, green: 0.97, blue: 0.96, alpha: 0.70).setFill()
targetPath.fill()

let dashedPath = NSBezierPath(roundedRect: targetRect, xRadius: cardRadius, yRadius: cardRadius)
let dashPattern: [CGFloat] = [7.0, 5.0]
dashedPath.setLineDash(dashPattern, count: dashPattern.count, phase: 0)
dashedPath.lineWidth = 2.0
jadeTintStroke.setStroke()
dashedPath.stroke()

// 5. Center Two-Tone Text: "drag and drop"
let textY: CGFloat = 248
let dragAndText = NSMutableAttributedString()
dragAndText.append(NSAttributedString(
    string: "drag and ",
    attributes: [
        .font: NSFont.systemFont(ofSize: 14, weight: .bold),
        .foregroundColor: ordalInk
    ]
))
dragAndText.append(NSAttributedString(
    string: "drop",
    attributes: [
        .font: NSFont.systemFont(ofSize: 14, weight: .bold),
        .foregroundColor: ordalJade
    ]
))
let textWidth = dragAndText.size().width
dragAndText.draw(at: CGPoint(x: (width - textWidth) / 2, y: textY))

// 6. Center Curved Arrow (Docker-style elegant smile curve with clean chevron)
let arrowColor = ordalJade

// Left card right edge is 253; right card left edge is 407.
let startPt = CGPoint(x: 265, y: 194)
let ctrl1 = CGPoint(x: 300, y: 142)
let ctrl2 = CGPoint(x: 360, y: 146)
let endPt = CGPoint(x: 395, y: 190)

let arrowPath = NSBezierPath()
arrowPath.move(to: startPt)
arrowPath.curve(to: endPt, controlPoint1: ctrl1, controlPoint2: ctrl2)
arrowPath.lineWidth = 4.0
arrowPath.lineCapStyle = .round
arrowColor.setStroke()
arrowPath.stroke()

// Chevron head
let tangentX = endPt.x - ctrl2.x
let tangentY = endPt.y - ctrl2.y
let tangentAngle = atan2(tangentY, tangentX)

let headLen: CGFloat = 18
let barbSpread: CGFloat = CGFloat.pi * 0.20

let wing1 = CGPoint(
    x: endPt.x + headLen * cos(tangentAngle + CGFloat.pi - barbSpread),
    y: endPt.y + headLen * sin(tangentAngle + CGFloat.pi - barbSpread)
)
let wing2 = CGPoint(
    x: endPt.x + headLen * cos(tangentAngle + CGFloat.pi + barbSpread),
    y: endPt.y + headLen * sin(tangentAngle + CGFloat.pi + barbSpread)
)

let chevron = NSBezierPath()
chevron.move(to: wing1)
chevron.line(to: endPt)
chevron.line(to: wing2)
chevron.lineWidth = 4.0
chevron.lineCapStyle = .round
chevron.lineJoinStyle = .round
arrowColor.setStroke()
chevron.stroke()

// 7. Footer
let footerFont = NSFont.systemFont(ofSize: 11, weight: .medium)
let footerAttributes: [NSAttributedString.Key: Any] = [
    .font: footerFont,
    .foregroundColor: NSColor(red: 0.55, green: 0.60, blue: 0.66, alpha: 1.0)
]
let footerStr = NSAttributedString(
    string: "Requires macOS 14.0 (Sonoma) or later",
    attributes: footerAttributes
)
let footerSize = footerStr.size()
footerStr.draw(at: CGPoint(x: (width - footerSize.width) / 2, y: 22))

// 8. Output PNG
guard let cgImage = context.makeImage() else {
    fatalError("Failed to create CGImage")
}

let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
bitmapRep.size = CGSize(width: width, height: height)
guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
    fatalError("Failed to convert image to PNG")
}

let fileManager = FileManager.default
let assetsDir = rootDir + "/assets/dmg"
try? fileManager.createDirectory(atPath: assetsDir, withIntermediateDirectories: true)

let output1xUrl = URL(fileURLWithPath: assetsDir + "/dmg-background.png")
let output2xUrl = URL(fileURLWithPath: assetsDir + "/dmg-background@2x.png")

try pngData.write(to: output1xUrl)
try pngData.write(to: output2xUrl)

print("Generated \(output1xUrl.path) and \(output2xUrl.path) successfully (\(pixelWidth)x\(pixelHeight) px)")
