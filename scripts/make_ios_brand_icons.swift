import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct Brand { let name: String; let fg: String; let bg: (CGFloat, CGFloat, CGFloat); let inset: CGFloat }
let base = "android/app/src"
let brands = [
  Brand(name: "gbled",     fg: "gbled/res/drawable-xxxhdpi/ic_launcher_foreground.png",     bg: (1, 1, 1),                      inset: 0.0),
  Brand(name: "viewplus",  fg: "viewplus/res/drawable-xxxhdpi/ic_launcher_foreground.png",  bg: (0xFE/255.0, 0xCD/255.0, 0x06/255.0), inset: -0.10),
  Brand(name: "mychannel", fg: "mychannel/res/drawable-xxxhdpi/ic_launcher_foreground.png", bg: (0x5E/255.0, 0x86/255.0, 0xA6/255.0), inset: 0.0),
  Brand(name: "ecoglow",   fg: "ecoglow/res/mipmap-xxxhdpi/ic_launcher_fg.png",             bg: (1, 1, 1),                      inset: 0.02),
]
let SIZE = 1024

for b in brands {
  let cs = CGColorSpaceCreateDeviceRGB()
  guard let ctx = CGContext(data: nil, width: SIZE, height: SIZE, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    print("ctx fail \(b.name)"); continue
  }
  ctx.setFillColor(red: b.bg.0, green: b.bg.1, blue: b.bg.2, alpha: 1)
  ctx.fill(CGRect(x: 0, y: 0, width: SIZE, height: SIZE))
  ctx.interpolationQuality = .high

  let fgURL = URL(fileURLWithPath: "\(base)/\(b.fg)")
  guard let src = CGImageSourceCreateWithURL(fgURL as CFURL, nil),
        let fg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    print("fg load fail \(b.name)"); continue
  }
  let m = CGFloat(SIZE) * b.inset
  ctx.draw(fg, in: CGRect(x: m, y: m, width: CGFloat(SIZE) - 2*m, height: CGFloat(SIZE) - 2*m))

  guard let outImg = ctx.makeImage() else { print("makeImage fail \(b.name)"); continue }
  let out = "assets/icon/brand_\(b.name).png"
  let outURL = URL(fileURLWithPath: out)
  guard let dest = CGImageDestinationCreateWithURL(outURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    print("dest fail \(b.name)"); continue
  }
  CGImageDestinationAddImage(dest, outImg, nil)
  if CGImageDestinationFinalize(dest) { print("wrote \(out)") } else { print("finalize fail \(b.name)") }
}
