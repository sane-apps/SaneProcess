#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'open3'
require 'optparse'
require 'tmpdir'
require 'yaml'

options = { platform: nil }
OptionParser.new do |parser|
  parser.banner = 'Usage: appstore_screenshot_compositor.rb --project PATH [--storyboard PATH] [--platform ios]'
  parser.on('--project PATH', 'App project root') { |value| options[:project] = value }
  parser.on('--storyboard PATH', 'Storyboard YAML (default: docs/appstore_screenshot_storyboard.yml)') { |value| options[:storyboard] = value }
  parser.on('--platform NAME', 'Render only one platform') { |value| options[:platform] = value }
end.parse!

abort 'Missing --project PATH' unless options[:project]
project = File.expand_path(options[:project])
storyboard_path = File.expand_path(options[:storyboard] || 'docs/appstore_screenshot_storyboard.yml', project)
abort "Storyboard not found: #{storyboard_path}" unless File.file?(storyboard_path)

storyboard = YAML.safe_load(File.read(storyboard_path), aliases: false)
brand = storyboard.fetch('brand')
canvas_defaults = storyboard.fetch('canvas', {})
platforms = storyboard.fetch('platforms')
platforms = platforms.select { |name, _| name == options[:platform] } if options[:platform]
abort "Platform not found: #{options[:platform]}" if platforms.empty?

swift_source = <<~'SWIFT'
  import AppKit
  import Foundation

  struct Spec: Decodable {
      let source: String
      let output: String
      let brand: String
      let title: String
      let subtitle: String
      let width: Int
      let height: Int
      let backgroundStart: String
      let backgroundEnd: String
      let accent: String
  }

  func color(_ hex: String) -> NSColor {
      let clean = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
      guard clean.count == 6, let value = Int(clean, radix: 16) else { return .black }
      return NSColor(
          calibratedRed: CGFloat((value >> 16) & 0xff) / 255,
          green: CGFloat((value >> 8) & 0xff) / 255,
          blue: CGFloat(value & 0xff) / 255,
          alpha: 1
      )
  }

  guard CommandLine.arguments.count == 2 else { fatalError("Expected a JSON spec path") }
  let spec = try JSONDecoder().decode(Spec.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
  guard let source = NSImage(contentsOfFile: spec.source) else { fatalError("Cannot read source image: \(spec.source)") }

  let canvasSize = NSSize(width: spec.width, height: spec.height)
  let image = NSImage(size: canvasSize)
  image.lockFocus()
  NSGraphicsContext.current?.imageInterpolation = .high

  NSGradient(starting: color(spec.backgroundStart), ending: color(spec.backgroundEnd))!
      .draw(in: NSRect(origin: .zero, size: canvasSize), angle: -82)

  let margin = CGFloat(spec.width) * 0.065
  let contentWidth = CGFloat(spec.width) - margin * 2
  let headlineHeight = CGFloat(spec.height) * 0.205
  let brandFont = NSFont.systemFont(ofSize: CGFloat(spec.width) * 0.025, weight: .bold)
  let titleFont = NSFont.systemFont(ofSize: CGFloat(spec.width) * 0.076, weight: .bold)
  let subtitleFont = NSFont.systemFont(ofSize: CGFloat(spec.width) * 0.038, weight: .medium)
  let paragraph = NSMutableParagraphStyle()
  paragraph.lineBreakMode = .byWordWrapping

  let brandRect = NSRect(x: margin, y: CGFloat(spec.height) - margin - brandFont.pointSize * 1.4,
                         width: contentWidth, height: brandFont.pointSize * 1.5)
  spec.brand.uppercased().draw(in: brandRect, withAttributes: [
      .font: brandFont, .foregroundColor: color(spec.accent), .kern: CGFloat(2.0)
  ])

  let titleRect = NSRect(x: margin, y: CGFloat(spec.height) - headlineHeight + CGFloat(spec.height) * 0.055,
                         width: contentWidth, height: headlineHeight * 0.55)
  spec.title.draw(in: titleRect, withAttributes: [
      .font: titleFont, .foregroundColor: NSColor.white, .paragraphStyle: paragraph
  ])
  let subtitleRect = NSRect(x: margin, y: CGFloat(spec.height) - headlineHeight + CGFloat(spec.height) * 0.018,
                            width: contentWidth, height: headlineHeight * 0.24)
  spec.subtitle.draw(in: subtitleRect, withAttributes: [
      .font: subtitleFont, .foregroundColor: NSColor.white.withAlphaComponent(0.92), .paragraphStyle: paragraph
  ])

  let imageAreaHeight = CGFloat(spec.height) - headlineHeight - margin * 0.55
  let sourceSize = source.size
  let scale = min(contentWidth / sourceSize.width, imageAreaHeight / sourceSize.height)
  let drawSize = NSSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
  let drawRect = NSRect(x: (CGFloat(spec.width) - drawSize.width) / 2,
                        y: margin * 0.35,
                        width: drawSize.width,
                        height: drawSize.height)
  let shadow = NSShadow()
  shadow.shadowColor = NSColor.black.withAlphaComponent(0.48)
  shadow.shadowBlurRadius = CGFloat(spec.width) * 0.035
  shadow.shadowOffset = NSSize(width: 0, height: -CGFloat(spec.width) * 0.012)
  shadow.set()
  let clip = NSBezierPath(roundedRect: drawRect, xRadius: CGFloat(spec.width) * 0.035, yRadius: CGFloat(spec.width) * 0.035)
  NSGraphicsContext.current?.saveGraphicsState()
  clip.addClip()
  source.draw(in: drawRect, from: .zero, operation: .copy, fraction: 1)
  NSGraphicsContext.current?.restoreGraphicsState()

  image.unlockFocus()
  guard let tiff = image.tiffRepresentation,
        let rep = NSBitmapImageRep(data: tiff),
        let png = rep.representation(using: .png, properties: [:]) else { fatalError("PNG encoding failed") }
  try FileManager.default.createDirectory(at: URL(fileURLWithPath: spec.output).deletingLastPathComponent(), withIntermediateDirectories: true)
  try png.write(to: URL(fileURLWithPath: spec.output), options: .atomic)
SWIFT

rendered = []
Dir.mktmpdir('appstore-compositor') do |tmpdir|
  swift_path = File.join(tmpdir, 'render.swift')
  File.write(swift_path, swift_source)
  platforms.each do |platform, shots|
    Array(shots).each_with_index do |shot, index|
      source = File.expand_path(shot.fetch('source'), project)
      output = File.expand_path(shot.fetch('file'), project)
      abort "Source not found: #{source}" unless File.file?(source)
      canvas = canvas_defaults.merge(storyboard.fetch('canvas_by_platform', {}).fetch(platform, {}))
      spec = {
        source: source,
        output: output,
        brand: brand,
        title: shot.fetch('title'),
        subtitle: shot.fetch('subtitle'),
        width: Integer(canvas.fetch('width')),
        height: Integer(canvas.fetch('height')),
        backgroundStart: canvas.fetch('background_start'),
        backgroundEnd: canvas.fetch('background_end'),
        accent: canvas.fetch('accent')
      }
      spec_path = File.join(tmpdir, "#{platform}-#{index}.json")
      File.write(spec_path, JSON.generate(spec))
      stdout, stderr, status = Open3.capture3('xcrun', 'swift', swift_path, spec_path)
      abort "Render failed for #{output}:\n#{stdout}\n#{stderr}" unless status.success?
      rendered << output
    end
  end
end

puts JSON.pretty_generate(rendered: rendered, count: rendered.length)
