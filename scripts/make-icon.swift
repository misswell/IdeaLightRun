// 生成 macOS AppIcon.icns：从带白底的图标原稿中定位深色圆角方块主体，
// 将圆角外置为透明（保留画布留白比例，Dock 中与其他应用图标大小一致），再输出全部尺寸。
// 用法: swift scripts/make-icon.swift <source.png> <output.icns>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("[make-icon] \(msg)\n".utf8))
    exit(1)
}

let args = CommandLine.arguments
guard args.count == 3 else { fail("用法: make-icon.swift <source.png> <output.icns>") }

guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fail("无法读取源图: \(args[1])") }

let w = image.width, h = image.height
guard w == h, w >= 512 else { fail("源图需为正方形且不小于 512px（当前 \(w)×\(h)）") }

guard let base = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                           space: CGColorSpaceCreateDeviceRGB(),
                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fail("无法创建位图上下文") }
base.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
guard let buf = base.data else { fail("无法读取像素") }
let px = buf.bindMemory(to: UInt8.self, capacity: w * h * 4)

func isDark(_ x: Int, _ y: Int) -> Bool {
    let i = (y * w + x) * 4
    let l = 0.299 * Double(px[i]) + 0.587 * Double(px[i + 1]) + 0.114 * Double(px[i + 2])
    return l < 120
}

// 图标本体（深色圆角方块）的包围盒。缓冲区第 0 行对应画布顶部。
var minX = w, minY = h, maxX = -1, maxY = -1
for y in 0..<h {
    for x in 0..<w where isDark(x, y) {
        minX = min(minX, x); maxX = max(maxX, x)
        minY = min(minY, y); maxY = max(maxY, y)
    }
}
guard maxX > minX, maxY > minY else { fail("未找到深色图标主体") }

func firstDarkX(_ y: Int, fromLeft: Bool) -> Int {
    if fromLeft {
        for x in minX...maxX where isDark(x, y) { return x }
        return maxX
    }
    for x in stride(from: maxX, through: minX, by: -1) where isDark(x, y) { return x }
    return minX
}

// 圆角半径：沿边缘扫描，边缘首次与包围盒齐平的行偏移即为半径
func cornerRadius(fromTop: Bool, fromLeft: Bool) -> Int {
    let anchor = fromTop ? minY : maxY
    var y = anchor
    let step = fromTop ? 1 : -1
    for _ in 0...(maxY - minY) {
        let x = firstDarkX(y, fromLeft: fromLeft)
        if abs(x - (fromLeft ? minX : maxX)) <= 1 { return abs(y - anchor) }
        y += step
    }
    return 0
}

let side = Double(maxX - minX + 1)
var radius = Double(cornerRadius(fromTop: true, fromLeft: true)
                  + cornerRadius(fromTop: true, fromLeft: false)
                  + cornerRadius(fromTop: false, fromLeft: true)
                  + cornerRadius(fromTop: false, fromLeft: false)) / 4
if radius < side * 0.10 || radius > side * 0.30 { radius = side * 0.2237 }

// 圆角外全部置为透明；蒙版矩形略内缩，裁掉贴边的白底抗锯齿
let inset = Int(max(2, side / 250))
let keepSide = side - Double(inset) * 2
let keep = CGRect(x: Double(minX + inset),
                  y: Double(h - maxY - 1 + inset),   // CGContext 原点在左下
                  width: keepSide,
                  height: keepSide)
guard let maskCtx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fail("无法创建蒙版上下文") }
maskCtx.addPath(CGPath(roundedRect: keep,
                       cornerWidth: max(0, radius - Double(inset)),
                       cornerHeight: max(0, radius - Double(inset)), transform: nil))
maskCtx.clip()
maskCtx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
guard let masked = maskCtx.makeImage() else { fail("无法生成蒙版图") }

func writePNG(_ cg: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fail("无法创建图像目标 \(url.path)")
    }
    CGImageDestinationAddImage(dest, cg, nil)
    guard CGImageDestinationFinalize(dest) else { fail("无法写入 \(url.path)") }
}

let sizes: [(Int, [String])] = [
    (16, ["icon_16x16.png"]),
    (32, ["icon_16x16@2x.png", "icon_32x32.png"]),
    (64, ["icon_32x32@2x.png"]),
    (128, ["icon_128x128.png"]),
    (256, ["icon_128x128@2x.png", "icon_256x256.png"]),
    (512, ["icon_256x256@2x.png", "icon_512x512.png"]),
    (1024, ["icon_512x512@2x.png"]),
]

let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("iconset-\(UUID().uuidString).iconset")
do { try fm.createDirectory(at: iconset, withIntermediateDirectories: true) } catch { fail("无法创建临时目录: \(error)") }

for (size, names) in sizes {
    let s = CGFloat(size)
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fail("无法创建 \(size)px 上下文") }
    ctx.interpolationQuality = .high
    ctx.draw(masked, in: CGRect(x: 0, y: 0, width: s, height: s))
    guard let out = ctx.makeImage() else { fail("无法生成 \(size)px 图像") }
    for name in names { writePNG(out, to: iconset.appendingPathComponent(name)) }
}

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", args[2]]
do { try p.run() } catch { fail("无法执行 iconutil: \(error)") }
p.waitUntilExit()
guard p.terminationStatus == 0 else { fail("iconutil 失败（exit \(p.terminationStatus)）") }
try? fm.removeItem(at: iconset)

let pct = Int(round(Double(side) / Double(w) * 100))
print("✅ 已生成 \(args[2])（主体占画布 \(pct)%，圆角 \(Int(radius / Double(side) * 1000) / 10)%，源图 \(w)×\(h)）")
