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
let outline = "<path d=\"\(commands.joined(separator: " "))\" fill=\"#000000\" stroke=\"#000000\" stroke-width=\"\(number(emboldenWidth))\" stroke-linejoin=\"round\" stroke-linecap=\"round\"/>"
let svg = """
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024" role="img" aria-labelledby="title description">
  <title id="title">pocahontas</title>
  <desc id="description">Black uppercase P on white, using the Contrail One glyph with synthetic bold and 12-degree oblique styling.</desc>
  <rect width="1024" height="1024" fill="#ffffff"/>
  \(outline)
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
let images: [[String: String]] = [["filename": "icon-1024.png", "idiom": "universal",
  "platform": "ios", "size": "1024x1024"]]
try writeJSON(["images": images, "info": info], to: icons.appendingPathComponent("Contents.json"))
try Data(contentsOf: directory.appendingPathComponent("pocahontas.png")).write(
  to: icons.appendingPathComponent("icon-1024.png"), options: .atomic)

let document = root.appendingPathComponent("Apps/macOS/MacAppIcon.icon")
let artwork = document.appendingPathComponent("Assets")
try FileManager.default.createDirectory(at: artwork, withIntermediateDirectories: true)
let foreground = """
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  \(outline)
</svg>

"""
try foreground.write(to: artwork.appendingPathComponent("P.svg"), atomically: true, encoding: .utf8)
try writeJSON([
  "color-space-for-untagged-svg-colors": "display-p3",
  "fill": ["solid": "srgb:1.00000,1.00000,1.00000,1.00000"],
  "groups": [[
    "name": "P", "layers": [["image-name": "P.svg", "name": "P", "glass": false]],
    "shadow": ["kind": "neutral", "opacity": 0], "specular": false,
    "translucency": ["enabled": false, "value": 0]
  ]],
  "supported-platforms": ["squares": "shared"]
], to: document.appendingPathComponent("icon.json"))
print("Generated the iPhone/iPad AppIcon catalog and native macOS Icon Composer document.")
