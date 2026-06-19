#!/usr/bin/env swift

import AppKit
import Foundation

private let canonicalSize = 1024
private let canonicalMargin = 100
private let cornerRadiusMultiplier: CGFloat = 0.225
private let alphaThreshold: CGFloat = 0.02

private func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(1)
}

private func value(after flag: String, in args: [String]) -> String? {
  guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else {
    return nil
  }
  return args[index + 1]
}

private func intValue(after flag: String, in args: [String], default defaultValue: Int) -> Int {
  guard let rawValue = value(after: flag, in: args) else {
    return defaultValue
  }
  guard let value = Int(rawValue), value > 0 else {
    fail("Invalid \(flag) value: \(rawValue)")
  }
  return value
}

private func scaledMargin(for size: Int) -> Int {
  Int((Double(size) * Double(canonicalMargin) / Double(canonicalSize)).rounded())
}

private func loadBitmap(path: String, expectedSize: Int, rendered: Bool) -> NSBitmapImageRep {
  guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
        let bitmap = NSBitmapImageRep(data: data) else {
    fail("Could not read image data: \(path)")
  }
  if !rendered || (bitmap.pixelsWide == expectedSize && bitmap.pixelsHigh == expectedSize) {
    return bitmap
  }

  guard let image = NSImage(data: data) else {
    fail("Could not render image data: \(path)")
  }
  return renderImageToBitmap(image: image, size: expectedSize)
}

private func renderImageToBitmap(image: NSImage, size: Int) -> NSBitmapImageRep {
  guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: size,
    pixelsHigh: size,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
  ) else {
    fail("Could not create \(size)x\(size) bitmap")
  }

  guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fail("Could not create graphics context")
  }

  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = context
  context.imageInterpolation = .high
  context.cgContext.clear(CGRect(x: 0, y: 0, width: size, height: size))
  image.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .sourceOver, fraction: 1.0)
  NSGraphicsContext.restoreGraphicsState()

  return bitmap
}

private func render(sourcePath: String, outputPath: String, size: Int) {
  guard let image = NSImage(contentsOfFile: sourcePath), image.isValid else {
    fail("Could not read source image: \(sourcePath)")
  }

  guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: size,
    pixelsHigh: size,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
  ) else {
    fail("Could not create \(size)x\(size) bitmap")
  }

  guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fail("Could not create graphics context")
  }

  let margin = scaledMargin(for: size)
  let innerSize = size - (margin * 2)
  let frame = NSRect(x: margin, y: margin, width: innerSize, height: innerSize)
  let cornerRadius = CGFloat(innerSize) * cornerRadiusMultiplier

  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = context
  context.imageInterpolation = .high
  context.cgContext.clear(CGRect(x: 0, y: 0, width: size, height: size))
  NSColor.clear.setFill()
  NSRect(x: 0, y: 0, width: size, height: size).fill()
  NSBezierPath(roundedRect: frame, xRadius: cornerRadius, yRadius: cornerRadius).addClip()
  image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1.0)
  NSGraphicsContext.restoreGraphicsState()

  guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
    fail("Could not encode PNG: \(outputPath)")
  }

  do {
    try FileManager.default.createDirectory(
      at: URL(fileURLWithPath: outputPath).deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try pngData.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
  } catch {
    fail("Could not write PNG \(outputPath): \(error.localizedDescription)")
  }
}

private func validate(path: String, expectedSize: Int, rendered: Bool) {
  let bitmap = loadBitmap(path: path, expectedSize: expectedSize, rendered: rendered)
  let width = bitmap.pixelsWide
  let height = bitmap.pixelsHigh
  guard width == expectedSize, height == expectedSize else {
    fail("Setapp icon is \(width)x\(height); Setapp requires \(expectedSize)x\(expectedSize).")
  }

  var minX = width
  var minY = height
  var maxX = -1
  var maxY = -1

  for y in 0..<height {
    for x in 0..<width {
      guard let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > alphaThreshold else {
        continue
      }
      minX = min(minX, x)
      minY = min(minY, y)
      maxX = max(maxX, x)
      maxY = max(maxY, y)
    }
  }

  guard maxX >= 0 else {
    fail("Setapp icon has no visible pixels.")
  }

  let margin = scaledMargin(for: expectedSize)
  let frameSize = expectedSize - (margin * 2)
  let maxAllowed = expectedSize - margin - 1
  if minX < margin || minY < margin || maxX > maxAllowed || maxY > maxAllowed {
    fail(
      "Setapp requires all visible pixels inside the centered \(frameSize)x\(frameSize) design frame " +
        "with \(margin)px margins; visible pixels span x=\(minX)...\(maxX), y=\(minY)...\(maxY)."
    )
  }

  validateRoundedCorners(bitmap: bitmap, margin: margin, maxAllowed: maxAllowed, frameSize: frameSize)

  let radius = Int((CGFloat(frameSize) * cornerRadiusMultiplier).rounded())
  print("ok visible_pixels=x=\(minX)...\(maxX),y=\(minY)...\(maxY) corner_curve=radius:\(radius)")
}

private func validateRoundedCorners(bitmap: NSBitmapImageRep, margin: Int, maxAllowed: Int, frameSize: Int) {
  let radius = CGFloat(frameSize) * cornerRadiusMultiplier
  let integerRadius = Int(ceil(radius))
  let mask = roundedMaskBitmap(
    size: bitmap.pixelsWide,
    frame: NSRect(x: margin, y: margin, width: frameSize, height: frameSize),
    radius: radius
  )
  let cornerRegions = [
    (margin..<(margin + integerRadius), margin..<(margin + integerRadius)),
    ((maxAllowed - integerRadius + 1)..<(maxAllowed + 1), margin..<(margin + integerRadius)),
    (margin..<(margin + integerRadius), (maxAllowed - integerRadius + 1)..<(maxAllowed + 1)),
    ((maxAllowed - integerRadius + 1)..<(maxAllowed + 1), (maxAllowed - integerRadius + 1)..<(maxAllowed + 1))
  ]

  var failures: [String] = []
  for (xRange, yRange) in cornerRegions {
    for y in yRange {
      for x in xRange {
        guard (mask.colorAt(x: x, y: y)?.alphaComponent ?? 0) <= alphaThreshold else {
          continue
        }
        guard bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0 > alphaThreshold else {
          continue
        }
        failures.append("(\(x),\(y))")
        if failures.count >= 8 {
          break
        }
      }
      if failures.count >= 8 {
        break
      }
    }
    if failures.count >= 8 {
      break
    }
  }

  guard failures.isEmpty else {
    fail("Setapp icon design corners must follow the rounded \(frameSize)x\(frameSize) frame; opaque outside-curve pixels include \(failures.joined(separator: ", ")).")
  }
}

private func roundedMaskBitmap(size: Int, frame: NSRect, radius: CGFloat) -> NSBitmapImageRep {
  guard let mask = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: size,
    pixelsHigh: size,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
  ) else {
    fail("Could not create rounded corner mask")
  }

  guard let context = NSGraphicsContext(bitmapImageRep: mask) else {
    fail("Could not create rounded corner mask context")
  }

  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = context
  context.shouldAntialias = true
  context.cgContext.clear(CGRect(x: 0, y: 0, width: size, height: size))
  NSColor.white.setFill()
  NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius).fill()
  NSGraphicsContext.restoreGraphicsState()

  return mask
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
  fail("Usage: setapp_icon_tool.swift render|validate ...")
}

switch command {
case "render":
  guard let source = value(after: "--source", in: args),
        let output = value(after: "--output", in: args) else {
    fail("Usage: setapp_icon_tool.swift render --source PATH --output PATH [--size N]")
  }
  render(sourcePath: source, outputPath: output, size: intValue(after: "--size", in: args, default: canonicalSize))
case "validate":
  guard let path = value(after: "--path", in: args) else {
    fail("Usage: setapp_icon_tool.swift validate --path PATH [--size N]")
  }
  validate(
    path: path,
    expectedSize: intValue(after: "--size", in: args, default: canonicalSize),
    rendered: args.contains("--rendered")
  )
default:
  fail("Unknown command: \(command)")
}
