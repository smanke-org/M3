#!/usr/bin/env swift
// Generates the app icon: a periodic-table style element tile — atomic number
// "27", tipped 45° to the left, the "M³" symbol, and the name along the bottom.
// Run with:
//   swift Tools/generate_icon.swift
//
// Produces two variants, because the name is an unreadable smudge at the 16
// and 32 point sizes macOS uses in Finder lists and dialogs:
//   Resources/AppIcon.png       — full tile, used from 128pt up
//   Resources/AppIcon-small.png — no name, larger symbol, used at 16-64pt

import AppKit

func renderIcon(includeName: Bool) -> NSImage {
let canvas: CGFloat = 1024
let image = NSImage(size: NSSize(width: canvas, height: canvas))

image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else {
    fatalError("no graphics context")
}

// A small margin keeps the tile from looking oversized beside other Dock icons.
let margin = canvas * 0.045
let tile = CGRect(x: margin, y: margin, width: canvas - margin * 2, height: canvas - margin * 2)
let side = tile.width
let cornerRadius = side * 0.215

let tilePath = CGPath(roundedRect: tile, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

// MARK: - Orange body

ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()

let colorSpace = CGColorSpaceCreateDeviceRGB()
let bodyColors = [
    NSColor(calibratedRed: 0.98, green: 0.49, blue: 0.13, alpha: 1.0).cgColor,
    NSColor(calibratedRed: 0.92, green: 0.37, blue: 0.02, alpha: 1.0).cgColor,
] as CFArray
let bodyGradient = CGGradient(colorsSpace: colorSpace, colors: bodyColors, locations: [0.0, 1.0])!
ctx.drawLinearGradient(
    bodyGradient,
    start: CGPoint(x: tile.minX, y: tile.maxY),
    end: CGPoint(x: tile.maxX, y: tile.minY),
    options: []
)

// Glossy sheen sweeping across the upper-left, as in the reference art.
let gloss = CGMutablePath()
gloss.move(to: CGPoint(x: tile.minX, y: tile.minY + side * 0.52))
gloss.addCurve(
    to: CGPoint(x: tile.minX + side * 0.68, y: tile.maxY),
    control1: CGPoint(x: tile.minX + side * 0.30, y: tile.minY + side * 0.78),
    control2: CGPoint(x: tile.minX + side * 0.34, y: tile.maxY)
)
gloss.addLine(to: CGPoint(x: tile.minX, y: tile.maxY))
gloss.closeSubpath()
ctx.addPath(gloss)
ctx.setFillColor(NSColor.white.withAlphaComponent(0.10).cgColor)
ctx.fillPath()

ctx.restoreGState()

// MARK: - Text

func draw(_ string: String, size: CGFloat, at point: CGPoint) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: .bold),
        .foregroundColor: NSColor.black,
    ]
    NSAttributedString(string: string, attributes: attributes).draw(at: point)
}

func size(of string: String, size: CGFloat) -> NSSize {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: .bold)
    ]
    return NSAttributedString(string: string, attributes: attributes).size()
}

// Atomic number, top-left, tipped 45° to the left (counterclockwise) about
// its own centre. Nudged up in the small variant so it still reads once the
// name is gone.
let number = "27"
let numberSize = side * (includeName ? 0.115 : 0.135)
let numberInset = side * 0.075
let numberBox = size(of: number, size: numberSize)
let numberCentre = CGPoint(
    x: tile.minX + numberInset + numberBox.width / 2,
    y: tile.maxY - numberInset - numberBox.height / 2
)
ctx.saveGState()
ctx.translateBy(x: numberCentre.x, y: numberCentre.y)
ctx.rotate(by: .pi / 4)
draw(number, size: numberSize, at: CGPoint(x: -numberBox.width / 2, y: -numberBox.height / 2))
ctx.restoreGState()

// "M" with a superscript "3", treated as one unit so it centres properly.
// Without the name below it, the symbol grows and recentres to fill the tile.
let symbolSize = side * (includeName ? 0.52 : 0.62)
let superscriptSize = symbolSize * 0.40
let mSize = size(of: "M", size: symbolSize)
let threeSize = size(of: "3", size: superscriptSize)

let symbolWidth = mSize.width + threeSize.width * 0.85
let symbolX = tile.midX - symbolWidth / 2
let symbolY = tile.minY + side * (includeName ? 0.28 : 0.20)

draw("M", size: symbolSize, at: CGPoint(x: symbolX, y: symbolY))
draw("3", size: superscriptSize, at: CGPoint(
    x: symbolX + mSize.width - threeSize.width * 0.12,
    y: symbolY + mSize.height * 0.44
))

// Name along the bottom.
if includeName {
    let nameSize = side * 0.077
    let name = "Mac Mouse Mileage"
    let nameWidth = size(of: name, size: nameSize).width
    draw(name, size: nameSize, at: CGPoint(
        x: tile.midX - nameWidth / 2,
        y: tile.minY + side * 0.105
    ))
}

image.unlockFocus()
return image
}

// MARK: - Write PNGs

func write(_ image: NSImage, to path: String) throws {
    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("failed to render PNG")
    }
    try png.write(to: URL(fileURLWithPath: path))
    print("Wrote \(path)")
}

try write(renderIcon(includeName: true), to: "Resources/AppIcon.png")
try write(renderIcon(includeName: false), to: "Resources/AppIcon-small.png")
