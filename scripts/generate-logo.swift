#!/usr/bin/env swift
import CoreGraphics
import CoreText
import Foundation
import ImageIO

// Run from the repository root: swift scripts/generate-logo.swift
// Contrail One ships only Regular. Embolden and oblique the original glyph;
// never substitute a different font or depend on an installed system font.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let directory = root.appendingPathComponent("assets/logo")
let fontURL = directory.appendingPathComponent("fonts/ContrailOne-Regular.ttf")
guard let provider = CGDataProvider(url: fontURL as CFURL),
  let graphicsFont = CGFont(provider)
else { fatalError("Unable to load the bundled Contrail One font") }
let font = CTFontCreateWithGraphicsFont(graphicsFont, 1000, nil, nil)
var character: UniChar = 0x0050 // P
var glyph: CGGlyph = 0
guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1),
  let original = CTFontCreatePathForGlyph(font, glyph, nil)
else { fatalError("Contrail One is missing the uppercase P glyph") }

let canvas = 1024
let glyphHeight: CGFloat = 704
let emboldenWidth: CGFloat = 12
let obliqueDegrees: CGFloat = 12
let scale = glyphHeight / original.boundingBoxOfPath.height
let shear = tan(obliqueDegrees * .pi / 180)
// SVG coordinates point down; CoreText glyph coordinates point up.
var transform = CGAffineTransform(a: scale, b: 0, c: shear * scale, d: -scale, tx: 0, ty: 0)
let shaped = original.copy(using: &transform)!
let bounds = shaped.boundingBoxOfPath
var center = CGAffineTransform(translationX: 512 - bounds.midX, y: 512 - bounds.midY)
let path = shaped.copy(using: &center)!

func drawGlyph(in context: CGContext) {
  context.setFillColor(CGColor(gray: 0, alpha: 1))
  context.setStrokeColor(CGColor(gray: 0, alpha: 1))
  context.setLineWidth(emboldenWidth)
  context.setLineJoin(.round)
  context.setLineCap(.round)
  context.addPath(path)
  context.drawPath(using: .fillStroke)
}

func number(_ value: CGFloat) -> String {
  String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), Double(value))
}
func point(_ value: CGPoint) -> String { "\(number(value.x)) \(number(value.y))" }
var commands: [String] = []
path.applyWithBlock { pointer in
  let element = pointer.pointee
  switch element.type {
  case .moveToPoint: commands.append("M \(point(element.points[0]))")
  case .addLineToPoint: commands.append("L \(point(element.points[0]))")
  case .addQuadCurveToPoint:
    commands.append("Q \(point(element.points[0])) \(point(element.points[1]))")
  case .addCurveToPoint:
    commands.append("C \(point(element.points[0])) \(point(element.points[1])) \(point(element.points[2]))")
  case .closeSubpath: commands.append("Z")
  @unknown default: fatalError("Unexpected glyph path element")
  }
}
let svg = """
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024" role="img" aria-labelledby="title description">
  <title id="title">pocahontas</title>
  <desc id="description">Black uppercase P on white, using the Contrail One glyph with synthetic bold and 12-degree oblique styling.</desc>
  <rect width="1024" height="1024" fill="#ffffff"/>
  <path d="\(commands.joined(separator: " "))" fill="#000000" stroke="#000000" stroke-width="\(number(emboldenWidth))" stroke-linejoin="round" stroke-linecap="round"/>
</svg>

"""
try svg.write(to: directory.appendingPathComponent("pocahontas.svg"), atomically: true, encoding: .utf8)

guard let context = CGContext(
  data: nil, width: canvas, height: canvas, bitsPerComponent: 8,
  bytesPerRow: canvas * 4, space: CGColorSpaceCreateDeviceRGB(),
  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
else { fatalError("Unable to create the opaque RGB canvas") }
context.setFillColor(CGColor(gray: 1, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: canvas, height: canvas))
context.translateBy(x: 0, y: CGFloat(canvas))
context.scaleBy(x: 1, y: -1)
drawGlyph(in: context)
guard let rendered = context.makeImage(),
  let destination = CGImageDestinationCreateWithURL(
    directory.appendingPathComponent("pocahontas.png") as CFURL, "public.png" as CFString, 1, nil)
else { fatalError("Unable to create the PNG output") }
CGImageDestinationAddImage(destination, rendered, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Unable to write the PNG") }
print("Generated pocahontas.svg and opaque 1024×1024 pocahontas.png from Contrail One.")

let catalog = root.appendingPathComponent("Apps/Shared/Assets.xcassets")
let icons = catalog.appendingPathComponent("AppIcon.appiconset")
try FileManager.default.createDirectory(at: icons, withIntermediateDirectories: true)
let info: [String: Any] = ["author": "xcode", "version": 1]
func writeJSON(_ value: [String: Any], to url: URL) throws {
  var data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
  data.append(0x0a)
  try data.write(to: url, options: .atomic)
}
try writeJSON(["info": info], to: catalog.appendingPathComponent("Contents.json"))
var images: [[String: String]] = [["filename": "icon-1024.png", "idiom": "universal",
  "platform": "ios", "size": "1024x1024"]]
for size in [16, 32, 128, 256, 512] {
  for scale in [1, 2] {
    images.append(["filename": "mac-icon-\(size * scale).png", "idiom": "mac",
      "size": "\(size)x\(size)", "scale": "\(scale)x"])
  }
}
try writeJSON(["images": images, "info": info], to: icons.appendingPathComponent("Contents.json"))
try Data(contentsOf: directory.appendingPathComponent("pocahontas.png")).write(
  to: icons.appendingPathComponent("icon-1024.png"), options: .atomic)

let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
let document = temporary.appendingPathComponent("Pocahontas.icon")
try FileManager.default.createDirectory(at: document, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
try writeJSON([
  "fill": ["solid": "srgb:1.00000,1.00000,1.00000,1.00000"],
  "groups": [],
  "supported-platforms": ["squares": "shared"]
], to: document.appendingPathComponent("icon.json"))
let selection = Process()
let selectedPath = Pipe()
selection.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
selection.arguments = ["-p"]
selection.standardOutput = selectedPath
try selection.run()
let developerPath = String(data: selectedPath.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!
selection.waitUntilExit()
guard selection.terminationStatus == 0 else { fatalError("Unable to locate Xcode") }
let developer = URL(fileURLWithPath: developerPath.trimmingCharacters(in: .whitespacesAndNewlines))
let composer = Process()
composer.executableURL = developer.deletingLastPathComponent().appendingPathComponent(
  "Applications/Icon Composer.app/Contents/Executables/ictool")
let roundedURL = temporary.appendingPathComponent("rounded.png")
composer.arguments = [document.path, "--export-image", "--output-file", roundedURL.path,
  "--platform", "macOS", "--rendition", "Default", "--width", "824", "--height", "824", "--scale", "1"]
try composer.run()
composer.waitUntilExit()
guard composer.terminationStatus == 0,
  let roundedSource = CGImageSourceCreateWithURL(roundedURL as CFURL, nil),
  let rounded = CGImageSourceCreateImageAtIndex(roundedSource, 0, nil)
else { fatalError("Unable to render the macOS icon with Icon Composer") }

for size in [16, 32, 64, 128, 256, 512, 1024] {
  guard let scaled = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
    bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
  else { fatalError("Unable to create the \(size) px icon canvas") }
  scaled.interpolationQuality = .high
  scaled.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
  scaled.draw(rounded, in: CGRect(x: 100, y: 100, width: 824, height: 824))
  scaled.setBlendMode(.sourceIn)
  scaled.setFillColor(CGColor(gray: 1, alpha: 1))
  scaled.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
  scaled.setBlendMode(.normal)
  scaled.translateBy(x: 100, y: 924)
  scaled.scaleBy(x: 824.0 / 1024, y: -824.0 / 1024)
  drawGlyph(in: scaled)
  guard let icon = scaled.makeImage(), let output = CGImageDestinationCreateWithURL(
    icons.appendingPathComponent("mac-icon-\(size).png") as CFURL, "public.png" as CFString, 1, nil)
  else { fatalError("Unable to create the \(size) px icon output") }
  CGImageDestinationAddImage(output, icon, nil)
  guard CGImageDestinationFinalize(output) else { fatalError("Unable to write the \(size) px icon") }
}
print("Generated the shared iPhone, iPad and Mac AppIcon asset catalog.")
