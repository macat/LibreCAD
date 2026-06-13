#!/usr/bin/env swift
//
//  make-icon.swift
//  LibreCADmacOS — app-icon generator
//
//  Draws the app icon entirely with CoreGraphics (NO network, NO external art) and
//  emits the full set of PNGs an `.iconset` needs. `make-app.sh` (or a manual run)
//  then turns the `.iconset` into `AppIcon.icns` with the system `iconutil`.
//
//  The mark: a draftsman's COMPASS (the classic CAD / technical-drawing motif)
//  opened over a faint blueprint grid, on a rounded-rect "squircle"-ish tile with a
//  soft blue gradient. It is built from primitives so it stays crisp and legible
//  from 16px to 1024px — at tiny sizes the grid fades and the compass legs read as a
//  bold inverted-V.
//
//  Usage:
//      swift make-icon.swift <output-iconset-dir>
//  Produces <output-iconset-dir>/icon_{16,32,128,256,512}x{,@2x}.png.
//  Reproducible: same code → same pixels. Source lives in the repo (this file).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Color helpers

private func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

// Palette — a confident technical blue, tuned to read on both light and dark Docks.
private let bgTop    = rgb(0.16, 0.40, 0.78)   // brighter blue (top)
private let bgBottom = rgb(0.07, 0.18, 0.42)   // deep navy (bottom)
private let gridInk  = rgb(1, 1, 1, 0.16)      // faint blueprint grid
private let metal    = rgb(0.92, 0.94, 0.98)   // compass body (near-white steel)
private let metalDk  = rgb(0.66, 0.72, 0.82)   // compass shading
private let leadTip  = rgb(0.10, 0.12, 0.18)   // pencil/needle tips
private let arc      = rgb(1.0, 0.78, 0.20, 0.95) // amber drawn arc (echoes selection color)

// MARK: - Icon drawing

/// Draws the full icon into `ctx` at the given pixel size (square). All geometry is
/// expressed as fractions of `s` so it scales cleanly to any size.
private func drawIcon(in ctx: CGContext, size s: CGFloat) {
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)

    // Flip to a TOP-LEFT origin, Y-DOWN coordinate space so all the geometry math
    // below reads naturally ("hinge near the top" = small Y, "tips near the bottom"
    // = large Y). A bare CGBitmapContext is Y-UP, which renders the compass
    // upside-down; this flip is the single fix for that. Everything (tile,
    // gradient, grid, compass) is drawn after the flip, so it all agrees.
    ctx.translateBy(x: 0, y: s)
    ctx.scaleBy(x: 1, y: -1)

    // --- Rounded tile (macOS "continuous" corner ~ 0.225 of the side) ----------
    // A modest margin keeps the mark off the very edge (like Apple's app tiles).
    let margin = s * 0.06
    let tile = CGRect(x: margin, y: margin, width: s - 2 * margin, height: s - 2 * margin)
    let corner = tile.width * 0.225
    let tilePath = CGPath(roundedRect: tile, cornerWidth: corner, cornerHeight: corner,
                          transform: nil)

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()

    // Vertical blue gradient background (Y-down: bgTop at minY, bgBottom at maxY).
    let space = CGColorSpaceCreateDeviceRGB()
    if let grad = CGGradient(colorsSpace: space,
                             colors: [bgTop, bgBottom] as CFArray,
                             locations: [0, 1]) {
        ctx.drawLinearGradient(grad,
                               start: CGPoint(x: tile.midX, y: tile.minY),
                               end: CGPoint(x: tile.midX, y: tile.maxY),
                               options: [])
    }

    // Blueprint grid (skip at tiny sizes where it would just be noise).
    if s >= 64 {
        ctx.setStrokeColor(gridInk)
        ctx.setLineWidth(max(1, s * 0.004))
        let step = tile.width / 8
        var x = tile.minX + step
        while x < tile.maxX { ctx.move(to: CGPoint(x: x, y: tile.minY))
                              ctx.addLine(to: CGPoint(x: x, y: tile.maxY)); x += step }
        var y = tile.minY + step
        while y < tile.maxY { ctx.move(to: CGPoint(x: tile.minX, y: y))
                              ctx.addLine(to: CGPoint(x: tile.maxX, y: y)); y += step }
        ctx.strokePath()
    }

    // --- The compass --------------------------------------------------------------
    // Geometry: a hinge near the top-center, two legs splayed into a V, with a small
    // pivot knob on top and tips at the bottom. The right leg holds an amber-drawn
    // arc to say "this draws geometry".
    let cx = tile.midX
    let hingeY = tile.minY + tile.height * 0.26      // hinge (top of the V)
    let tipY   = tile.minY + tile.height * 0.80      // leg tips (bottom)
    let spread = tile.width * 0.20                   // half-distance between tips
    let legW   = max(2, s * 0.052)                   // leg thickness

    let hinge = CGPoint(x: cx, y: hingeY)
    let leftTip  = CGPoint(x: cx - spread, y: tipY)
    let rightTip = CGPoint(x: cx + spread, y: tipY)

    // The arc the compass is tracing: centered on the LEFT tip (the needle/pivot),
    // with a radius equal to the leg-tip span so it passes THROUGH the right tip.
    // It sweeps a short way past the right tip (the pencil's drawing motion). Drawn
    // first so the leg/tip overlay its starting end and it reads as "in progress".
    // (Y-DOWN space: angle measured from +x, increasing angle goes clockwise on
    // screen — so we start a little above the right tip and sweep downward past it.)
    if s >= 48 {
        let radius = hypot(rightTip.x - leftTip.x, rightTip.y - leftTip.y)
        // Angle from the left tip to the right tip (the through-point), in Y-down space.
        let toRight = atan2(rightTip.y - leftTip.y, rightTip.x - leftTip.x)
        ctx.setStrokeColor(arc)
        ctx.setLineCap(.round)
        ctx.setLineWidth(max(2, s * 0.030))
        ctx.addArc(center: leftTip, radius: radius,
                   startAngle: toRight - 0.20,   // just shy of the right tip
                   endAngle: toRight + 0.55,     // sweep past it (drawing motion)
                   clockwise: false)
        ctx.strokePath()
    }

    // Leg drawing helper: a tapered capsule from hinge to tip, with a darker inner
    // edge for a hint of metal shading and a dark tip.
    func drawLeg(to tip: CGPoint, tipInner: Bool) {
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        // Body.
        ctx.setStrokeColor(metal)
        ctx.setLineWidth(legW)
        ctx.move(to: hinge); ctx.addLine(to: tip); ctx.strokePath()
        // Shading edge (thin, offset toward center).
        ctx.setStrokeColor(metalDk)
        ctx.setLineWidth(max(1, legW * 0.28))
        let mid = CGPoint(x: (hinge.x + tip.x) / 2, y: (hinge.y + tip.y) / 2)
        ctx.move(to: mid); ctx.addLine(to: tip); ctx.strokePath()
        // Sharp tip (needle / pencil lead).
        ctx.setFillColor(leadTip)
        let tr = legW * 0.42
        ctx.beginPath()
        ctx.move(to: CGPoint(x: tip.x, y: tip.y + tr * 1.4))      // point downward
        ctx.addLine(to: CGPoint(x: tip.x - tr, y: tip.y - tr * 0.3))
        ctx.addLine(to: CGPoint(x: tip.x + tr, y: tip.y - tr * 0.3))
        ctx.closePath()
        ctx.fillPath()
    }
    drawLeg(to: leftTip,  tipInner: false)
    drawLeg(to: rightTip, tipInner: true)

    // Hinge knob (pivot) + a little finial on top.
    ctx.setFillColor(metal)
    let knobR = legW * 0.95
    ctx.fillEllipse(in: CGRect(x: hinge.x - knobR, y: hinge.y - knobR,
                               width: knobR * 2, height: knobR * 2))
    ctx.setFillColor(metalDk)
    let innerR = knobR * 0.45
    ctx.fillEllipse(in: CGRect(x: hinge.x - innerR, y: hinge.y - innerR,
                               width: innerR * 2, height: innerR * 2))
    // Finial stem above the hinge.
    ctx.setStrokeColor(metal)
    ctx.setLineCap(.round)
    ctx.setLineWidth(legW * 0.55)
    ctx.move(to: hinge)
    ctx.addLine(to: CGPoint(x: hinge.x, y: hinge.y - tile.height * 0.10))
    ctx.strokePath()

    ctx.restoreGState()

    // Subtle inner top highlight on the tile for a little gloss (over everything,
    // clipped to the tile). Skipped at tiny sizes.
    if s >= 128 {
        ctx.saveGState()
        ctx.addPath(tilePath); ctx.clip()
        if let gloss = CGGradient(colorsSpace: space,
                                  colors: [rgb(1, 1, 1, 0.18), rgb(1, 1, 1, 0)] as CFArray,
                                  locations: [0, 1]) {
            // Top-down gloss (Y-down): brightest at the top edge, fading to the middle.
            ctx.drawLinearGradient(gloss,
                                   start: CGPoint(x: tile.midX, y: tile.minY),
                                   end: CGPoint(x: tile.midX, y: tile.midY),
                                   options: [])
        }
        ctx.restoreGState()
    }
}

// MARK: - PNG rendering

private func renderPNG(pixels: Int, to url: URL) {
    let space = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: pixels, height: pixels,
                              bitsPerComponent: 8, bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        FileHandle.standardError.write("error: could not create \(pixels)px context\n".data(using: .utf8)!)
        exit(1)
    }
    drawIcon(in: ctx, size: CGFloat(pixels))
    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        FileHandle.standardError.write("error: could not encode \(url.lastPathComponent)\n".data(using: .utf8)!)
        exit(1)
    }
    CGImageDestinationAddImage(dest, image, nil)
    if !CGImageDestinationFinalize(dest) {
        FileHandle.standardError.write("error: could not write \(url.lastPathComponent)\n".data(using: .utf8)!)
        exit(1)
    }
}

// MARK: - Main

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write("usage: swift make-icon.swift <output-iconset-dir>\n".data(using: .utf8)!)
    exit(2)
}
let outDir = URL(fileURLWithPath: args[1], isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// The standard macOS .iconset entries: (filename, pixel size).
let entries: [(String, Int)] = [
    ("icon_16x16.png", 16),       ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),       ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),    ("icon_512x512@2x.png", 1024),
]
for (name, px) in entries {
    renderPNG(pixels: px, to: outDir.appendingPathComponent(name))
    print("  wrote \(name) (\(px)px)")
}
print("iconset PNGs written to \(outDir.path)")
