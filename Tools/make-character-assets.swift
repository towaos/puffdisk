// キャラクターの絵（DESIGN.md 5.1）を原画から作る。絵を差し替えるときだけ手で実行する。
//
//   swiftc -O Tools/make-character-assets.swift -o /tmp/make-character-assets
//   /tmp/make-character-assets Art/hamsters.png Puffdisk/Resources/Assets.xcassets
//
// 原画は5匹を横に並べた1枚の透過 PNG。体を塗りつぶし、内側の線を透明に抜いた次の2種類のテンプレート画像を書き出す。
// - Hamster1〜5: ポップオーバー用。原画の線そのまま
// - MenuBarHamster1〜5: メニューバー用。18pt では原画の線が細すぎて手や種がつぶれるので、
//   部位ごとに線を太らせる。原画の 1〜3 はほぼ同じ幅なので、幅を段階ごとに決めて太さの違いを出す
import AppKit

/// 段階ごとのメニューバーでの幅（pt）。D9 の 16〜22pt に収める
let menuBarWidths = [16, 17, 18, 19, 22]
let menuBarHeight = 18
/// メニューバー用に線を太らせる量（原画のピクセル）
enum Stroke {
    static let outline = 3.5, spark = 3.0, eye = 2.5, nose = 2.0, hands = 1.5
}

struct Layer {
    let width: Int, height: Int
    var values: [Float]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        values = .init(repeating: 0, count: width * height)
    }

    subscript(x: Int, y: Int) -> Float {
        get { x < 0 || y < 0 || x >= width || y >= height ? 0 : values[y * width + x] }
        set { values[y * width + x] = newValue }
    }

    func dilated(by radius: Double) -> Layer {
        let reach = Int(radius.rounded(.up))
        var offsets: [(Int, Int)] = []
        for dy in -reach...reach {
            for dx in -reach...reach where Double(dx * dx + dy * dy) <= radius * radius { offsets.append((dx, dy)) }
        }
        var output = Layer(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width where self[x, y] > 0 {
                for (dx, dy) in offsets where x + dx >= 0 && y + dy >= 0 && x + dx < width && y + dy < height {
                    output[x + dx, y + dy] = 1
                }
            }
        }
        return output
    }

    /// 面積平均で縮める
    func resized(width newWidth: Int, height newHeight: Int) -> Layer {
        var output = Layer(width: newWidth, height: newHeight)
        let (stepX, stepY) = (Double(width) / Double(newWidth), Double(height) / Double(newHeight))
        for ty in 0..<newHeight {
            let (y0, y1) = (Double(ty) * stepY, Double(ty + 1) * stepY)
            for tx in 0..<newWidth {
                let (x0, x1) = (Double(tx) * stepX, Double(tx + 1) * stepX)
                var sum = 0.0
                var sy = Int(y0)
                while Double(sy) < y1, sy < height {
                    let coverY = min(y1, Double(sy + 1)) - max(y0, Double(sy))
                    var sx = Int(x0)
                    while Double(sx) < x1, sx < width {
                        sum += Double(self[sx, sy]) * coverY * (min(x1, Double(sx + 1)) - max(x0, Double(sx)))
                        sx += 1
                    }
                    sy += 1
                }
                output[tx, ty] = Float(sum / (stepX * stepY))
            }
        }
        return output
    }
}

struct Component {
    var pixels: [(Int, Int)] = []
    var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
    var boxWidth: Int { maxX - minX + 1 }
    var boxHeight: Int { maxY - minY + 1 }
    var midX: Int { (minX + maxX) / 2 }
    var midY: Int { (minY + maxY) / 2 }
}

func components(of layer: Layer) -> [Component] {
    var visited = [Bool](repeating: false, count: layer.width * layer.height)
    var result: [Component] = []
    for start in 0..<visited.count where layer.values[start] > 0.5 && !visited[start] {
        var component = Component()
        var stack = [start]
        visited[start] = true
        while let index = stack.popLast() {
            let (x, y) = (index % layer.width, index / layer.width)
            component.pixels.append((x, y))
            component.minX = min(component.minX, x)
            component.maxX = max(component.maxX, x)
            component.minY = min(component.minY, y)
            component.maxY = max(component.maxY, y)
            for dy in -1...1 {
                for dx in -1...1 where layer[x + dx, y + dy] > 0.5 {
                    let next = (y + dy) * layer.width + x + dx
                    if !visited[next] {
                        visited[next] = true
                        stack.append(next)
                    }
                }
            }
        }
        result.append(component)
    }
    return result
}

func bodyMask(of fill: Layer) -> Layer {
    var mask = Layer(width: fill.width, height: fill.height)
    for (x, y) in components(of: fill).max(by: { $0.pixels.count < $1.pixels.count })!.pixels { mask[x, y] = 1 }
    return mask
}

/// 線を部位に分け、部位ごとに太らせる
/// - Returns: 体の外周と外の線（塗りに足す）、顔と手の線（塗りから抜く）
func menuBarLines(ink: Layer, body: Layer) -> (outer: Layer, inner: Layer) {
    let parts = components(of: ink).filter { $0.pixels.count >= 8 }
    let outline = parts.max { $0.pixels.count < $1.pixels.count }!

    var outer = Layer(width: ink.width, height: ink.height)
    var inner = Layer(width: ink.width, height: ink.height)
    for part in parts {
        var mask = Layer(width: ink.width, height: ink.height)
        for (x, y) in part.pixels { mask[x, y] = 1 }

        let radius: Double
        let isOuter: Bool
        let filledRatio = Double(part.pixels.count) / Double(part.boxWidth * part.boxHeight)
        if part.minX == outline.minX {
            (radius, isOuter) = (Stroke.outline, true)
        } else if body[part.pixels[0].0, part.pixels[0].1] == 0 {
            // 体の外にあるのは段階5の「はちきれそう」の線だけ
            (radius, isOuter) = (Stroke.spark, true)
        } else if Double(part.midY) < Double(outline.minY) + Double(outline.boxHeight) * 0.25 {
            // 耳の内側の線。18pt では耳がつぶれるだけなので描かない
            continue
        } else if part.boxWidth < 24, part.boxHeight < 24 {
            (radius, isOuter) = (Stroke.nose, false)
        } else if filledRatio > 0.6 {
            (radius, isOuter) = (Stroke.eye, false)
        } else {
            (radius, isOuter) = (Stroke.hands, false)
        }
        let thick = mask.dilated(by: radius)
        for index in thick.values.indices where thick.values[index] > 0 {
            if isOuter { outer.values[index] = 1 } else { inner.values[index] = 1 }
        }
    }
    return (outer, inner)
}

/// 原画の線のうち、顔と手など体の内側のものだけを残す。外周につながる線は残さない
func innerLines(ink: Layer, body: Layer) -> Layer {
    let parts = components(of: ink).filter { $0.pixels.count >= 8 }
    let outline = parts.max { $0.pixels.count < $1.pixels.count }!
    var output = Layer(width: ink.width, height: ink.height)
    for part in parts where part.minX != outline.minX && body[part.pixels[0].0, part.pixels[0].1] > 0 {
        var mask = Layer(width: ink.width, height: ink.height)
        for (x, y) in part.pixels { mask[x, y] = 1 }
        // 線の縁のぼかしも含める
        let edge = mask.dilated(by: 2)
        for index in edge.values.indices where edge.values[index] > 0 { output.values[index] = ink.values[index] }
    }
    return output
}

/// 塗りから線を抜く
func knockingOut(lines: Layer, from solid: Layer) -> Layer {
    var output = solid
    for index in output.values.indices { output.values[index] *= 1 - lines.values[index] }
    return output
}

func writePNG(_ image: Layer, to url: URL) throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: image.width, pixelsHigh: image.height,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    for y in 0..<image.height {
        for x in 0..<image.width {
            var pixel = [0, 0, 0, Int((image[x, y] * 255).rounded())]
            bitmap.setPixel(&pixel, atX: x, y: y)
        }
    }
    try bitmap.representation(using: .png, properties: [:])!.write(to: url)
}

func writeImageSet(name: String, images: [(scale: String, image: Layer)], in catalog: URL) throws {
    let folder = catalog.appending(path: "\(name).imageset", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var entries: [[String: String]] = []
    for image in images {
        let file = "\(name)@\(image.scale).png"
        try writePNG(image.image, to: folder.appending(path: file))
        entries.append(["filename": file, "idiom": "mac", "scale": image.scale])
    }
    let contents: [String: Any] = [
        "images": entries,
        "info": ["author": "xcode", "version": 1],
        "properties": ["template-rendering-intent": "template"],
    ]
    let data = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: folder.appending(path: "Contents.json"))
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    print("使い方: make-character-assets <原画.png> <Assets.xcassets>")
    exit(2)
}
let source = NSBitmapImageRep(data: try Data(contentsOf: URL(filePath: arguments[1])))!
let catalog = URL(filePath: arguments[2], directoryHint: .isDirectory)
let (sourceWidth, sourceHeight) = (source.pixelsWide, source.pixelsHigh)

// 原画を線と塗りに分ける。塗りのわずかなムラと半透明は消す
var sourceInk = Layer(width: sourceWidth, height: sourceHeight)
var sourceFill = Layer(width: sourceWidth, height: sourceHeight)
var pixel = [Int](repeating: 0, count: 4)
for y in 0..<sourceHeight {
    for x in 0..<sourceWidth {
        source.getPixel(&pixel, atX: x, y: y)
        let alpha = Float(pixel[3]) / 255
        let luminance = (Float(pixel[0]) * 0.3 + Float(pixel[1]) * 0.59 + Float(pixel[2]) * 0.11) / 255
        sourceFill[x, y] = min(1, alpha / 0.8)
        sourceInk[x, y] = max(0, min(1, (0.8 - luminance) / 0.6)) * min(1, alpha / 0.8)
    }
}

// 列の切れ目で5匹に分ける
var columns: [ClosedRange<Int>] = []
var runStart: Int?
for x in 0...sourceWidth {
    let hasContent = x < sourceWidth && (0..<sourceHeight).contains { sourceFill[x, $0] > 0.5 }
    if hasContent, runStart == nil { runStart = x }
    if !hasContent, let start = runStart {
        columns.append(start...(x - 1))
        runStart = nil
    }
}
guard columns.count == menuBarWidths.count else { fatalError("原画の列が \(columns.count) 個ある") }

let rows = (0..<sourceHeight).filter { y in (0..<sourceWidth).contains { sourceFill[$0, y] > 0.5 } }
let (top, bottom) = (rows.first!, rows.last!)
let margin = Int(Stroke.outline.rounded(.up)) + 1

for (index, column) in columns.enumerated() {
    // 同じ高さの枠に、下端をそろえて切り出す
    let (width, height) = (column.count + margin * 2, bottom - top + 1 + margin * 2)
    var ink = Layer(width: width, height: height)
    var fill = Layer(width: width, height: height)
    var columnBottom = 0
    for y in top...bottom where column.contains(where: { sourceFill[$0, y] > 0.5 }) { columnBottom = y }
    for y in 0..<height {
        for x in 0..<width {
            let (sx, sy) = (column.lowerBound + x - margin, columnBottom - (height - 1 - y) + margin)
            guard sx >= 0, sy >= 0, sx < sourceWidth, sy < sourceHeight, column.contains(sx) else { continue }
            ink[x, y] = sourceInk[sx, sy]
            fill[x, y] = sourceFill[sx, sy]
        }
    }

    // 枠の高さは原画の解像度のまま。@2x にすると 127pt 相当で、ポップオーバーには十分
    let body = bodyMask(of: fill)
    let illustration = knockingOut(lines: innerLines(ink: ink, body: body), from: fill)
    try writeImageSet(name: "Hamster\(index + 1)", images: [("2x", illustration)], in: catalog)

    let lines = menuBarLines(ink: ink, body: body)
    var solid = lines.outer
    for index in solid.values.indices { solid.values[index] = max(solid.values[index], body.values[index]) }
    let menuBar = knockingOut(lines: lines.inner, from: solid)
    let images = [1, 2].map { scale in
        (scale: "\(scale)x", image: menuBar.resized(width: menuBarWidths[index] * scale, height: menuBarHeight * scale))
    }
    try writeImageSet(name: "MenuBarHamster\(index + 1)", images: images, in: catalog)
}

let contents = ["info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: catalog.appending(path: "Contents.json"))
print("書き出した: \(catalog.path(percentEncoded: false))")
