// Render color emoji to square PNG files for Ebox on macOS.
//
// Usage: emoji-render DIRECTORY
// Each stdin line is "SIZE<TAB>NAME<TAB>TEXT".  The program writes
// DIRECTORY/NAME.png, SIZE pixels square, and prints NAME, or "!NAME" when
// it cannot render.  It exits at end of input.
import AppKit

let directory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func render(_ text: String, size: CGFloat, to path: String) -> Bool {
  let side = Int(size)
  guard let context = CGContext(
          data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
  else { return false }
  // Fit the glyph's ink, not its font line, into the square: a color emoji
  // font's line box is much taller than its glyphs.
  func line(_ points: CGFloat) -> CTLine {
    let font = CTFontCreateWithName("Apple Color Emoji" as CFString, points, nil)
    return CTLineCreateWithAttributedString(
      NSAttributedString(string: text, attributes: [.font: font]))
  }
  let margin = size * 0.04
  var points = size
  var ink = CTLineGetBoundsWithOptions(line(points), .useGlyphPathBounds)
  if ink.width <= 0 || ink.height <= 0 { return false }
  points *= min((size - 2 * margin) / ink.width, (size - 2 * margin) / ink.height)
  let fitted = line(points)
  ink = CTLineGetBoundsWithOptions(fitted, .useGlyphPathBounds)
  context.textPosition = CGPoint(x: (size - ink.width) / 2 - ink.minX,
                                 y: (size - ink.height) / 2 - ink.minY)
  CTLineDraw(fitted, context)
  guard let image = context.makeImage() else { return false }
  let rep = NSBitmapImageRep(cgImage: image)
  guard let png = rep.representation(using: .png, properties: [:]) else { return false }
  return (try? png.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil
}

while let line = readLine() {
  let fields = line.split(separator: "\t", maxSplits: 2).map(String.init)
  guard fields.count == 3, let size = Double(fields[0]), size > 0 else { continue }
  let ok = render(fields[2], size: CGFloat(size), to: directory + "/" + fields[1] + ".png")
  print(ok ? fields[1] : "!" + fields[1])
  fflush(stdout)
}
