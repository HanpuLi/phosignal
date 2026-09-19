import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("usage: make-icon.swift <output-png>\n", stderr)
    exit(2)
}

let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()
let rect = NSRect(origin: .zero, size: size)
let background = NSBezierPath(roundedRect: rect.insetBy(dx: 48, dy: 48), xRadius: 220, yRadius: 220)
NSColor(calibratedRed: 0.075, green: 0.09, blue: 0.12, alpha: 1).setFill()
background.fill()
let ringRect = rect.insetBy(dx: 188, dy: 188)
let ring = NSBezierPath(ovalIn: ringRect)
ring.lineWidth = 56
NSColor(calibratedRed: 0.20, green: 0.88, blue: 0.55, alpha: 1).setStroke()
ring.stroke()
let dotRect = NSRect(x: 388, y: 388, width: 248, height: 248)
NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.20, alpha: 1).setFill()
NSBezierPath(ovalIn: dotRect).fill()
image.unlockFocus()
guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fputs("failed to render icon\n", stderr)
    exit(1)
}
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
