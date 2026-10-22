import CoreGraphics
import Foundation

/// Palette (8-bit indexed) PNG output with a full alpha table, for compressing
/// PNGs whose transparency has soft edges. ffmpeg's paletteuse only keeps on/off
/// transparency, so these images are quantized natively.
enum PNGPalette {
    enum AlphaKind { case opaque, binary, soft }

    /// RGBA pixels, premultiplied, in sRGB.
    struct Pixels {
        var width: Int
        var height: Int
        var data: [UInt8]
    }

    static func pixels(of image: CGImage) -> Pixels? {
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = data.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? Pixels(width: width, height: height, data: data) : nil
    }

    static func alphaKind(of image: CGImage) -> AlphaKind {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return .opaque
        default: break
        }
        guard let pixels = pixels(of: image) else { return .soft }
        var sawTransparent = false
        var index = 3
        let count = pixels.data.count
        return pixels.data.withUnsafeBufferPointer { buffer -> AlphaKind in
            while index < count {
                let alpha = buffer[index]
                if alpha != 255 {
                    if alpha != 0 { return .soft }
                    sawTransparent = true
                }
                index += 4
            }
            return sawTransparent ? .binary : .opaque
        }
    }

    /// Quantizes to at most `colors` RGBA entries with median cut and writes an indexed PNG.
    static func writeQuantized(_ image: CGImage, colors: Int, to url: URL) throws {
        guard let pixels = pixels(of: image) else { throw GeneralToolFailure("Could not create the PNG image.") }
        let (palette, indices) = quantize(pixels, colors: max(2, min(256, colors)))
        let data = try encodePNG(width: pixels.width, height: pixels.height, palette: palette, indices: indices)
        try data.write(to: url)
    }

    // MARK: Median cut

    private struct Bucket {
        var count: Int
        var r: Int, g: Int, b: Int, a: Int // sums of 8-bit premultiplied values
        var key: Int // 5-bit-per-channel color key
    }

    private struct Box {
        var range: Range<Int> // indices into the bucket array
        var population: Int
        var channel = 0
        var score = 0
    }

    /// Returns a non-premultiplied RGBA palette and one palette index per pixel.
    static func quantize(_ pixels: Pixels, colors: Int) -> (palette: [[UInt8]], indices: [UInt8]) {
        let pixelCount = pixels.width * pixels.height
        // Histogram over 5 bits per channel (premultiplied).
        var counts = [Int32](repeating: 0, count: 1 << 20)
        var sums = [Int64](repeating: 0, count: (1 << 20) * 4)
        pixels.data.withUnsafeBufferPointer { data in
            counts.withUnsafeMutableBufferPointer { counts in
                sums.withUnsafeMutableBufferPointer { sums in
                    for pixel in 0..<pixelCount {
                        let offset = pixel * 4
                        let r = Int(data[offset]), g = Int(data[offset + 1]), b = Int(data[offset + 2]), a = Int(data[offset + 3])
                        let key = (r >> 3) << 15 | (g >> 3) << 10 | (b >> 3) << 5 | (a >> 3)
                        counts[key] += 1
                        sums[key * 4] += Int64(r)
                        sums[key * 4 + 1] += Int64(g)
                        sums[key * 4 + 2] += Int64(b)
                        sums[key * 4 + 3] += Int64(a)
                    }
                }
            }
        }
        var buckets: [Bucket] = []
        buckets.reserveCapacity(4096)
        for key in 0..<(1 << 20) where counts[key] > 0 {
            buckets.append(Bucket(count: Int(counts[key]), r: Int(sums[key * 4]), g: Int(sums[key * 4 + 1]),
                                  b: Int(sums[key * 4 + 2]), a: Int(sums[key * 4 + 3]), key: key))
        }

        func channel(_ bucket: Bucket, _ index: Int) -> Int {
            switch index {
            case 0: return bucket.r / bucket.count
            case 1: return bucket.g / bucket.count
            case 2: return bucket.b / bucket.count
            default: return bucket.a / bucket.count
            }
        }
        // Each box remembers its widest channel and a population-weighted score.
        func measured(_ range: Range<Int>, population: Int) -> Box {
            var box = Box(range: range, population: population)
            guard range.count > 1 else { return box }
            var low = [255, 255, 255, 255], high = [0, 0, 0, 0]
            for i in range {
                let bucket = buckets[i]
                for c in 0..<4 {
                    let value = channel(bucket, c)
                    if value < low[c] { low[c] = value }
                    if value > high[c] { high[c] = value }
                }
            }
            let weight = Int(Double(population).squareRoot())
            for c in 0..<4 where (high[c] - low[c]) * weight > box.score {
                box.score = (high[c] - low[c]) * weight
                box.channel = c
            }
            return box
        }
        var boxes = [measured(0..<buckets.count, population: pixelCount)]
        while boxes.count < colors {
            guard let bestBox = boxes.indices.max(by: { boxes[$0].score < boxes[$1].score }), boxes[bestBox].score > 0 else { break }
            let box = boxes[bestBox]
            let bestChannel = box.channel
            buckets[box.range].sort { channel($0, bestChannel) < channel($1, bestChannel) }
            var running = 0
            var split = box.range.lowerBound + 1
            for i in box.range {
                running += buckets[i].count
                if running * 2 >= box.population {
                    split = min(max(i + 1, box.range.lowerBound + 1), box.range.upperBound - 1)
                    break
                }
            }
            let first = box.range.lowerBound..<split
            let second = split..<box.range.upperBound
            let firstPopulation = buckets[first].reduce(0) { $0 + $1.count }
            boxes[bestBox] = measured(first, population: firstPopulation)
            boxes.append(measured(second, population: box.population - firstPopulation))
        }

        // Palette entries: weighted averages, stored premultiplied for matching.
        var premultiplied: [(r: Int, g: Int, b: Int, a: Int)] = []
        var lookup = [UInt8](repeating: 0, count: 1 << 20)
        for (index, box) in boxes.enumerated() {
            var r = 0, g = 0, b = 0, a = 0, n = 0
            for i in box.range {
                r += buckets[i].r; g += buckets[i].g; b += buckets[i].b; a += buckets[i].a; n += buckets[i].count
                lookup[buckets[i].key] = UInt8(index)
            }
            n = max(n, 1)
            premultiplied.append(((r + n / 2) / n, (g + n / 2) / n, (b + n / 2) / n, (a + n / 2) / n))
        }
        // Order transparent entries first so the tRNS table stays short.
        let order = premultiplied.indices.sorted { premultiplied[$0].a < premultiplied[$1].a }
        var remap = [UInt8](repeating: 0, count: premultiplied.count)
        for (newIndex, oldIndex) in order.enumerated() { remap[oldIndex] = UInt8(newIndex) }
        let palette: [[UInt8]] = order.map { entry in
            let color = premultiplied[entry]
            guard color.a > 0 else { return [0, 0, 0, 0] }
            func unpremultiply(_ value: Int) -> UInt8 { UInt8(min(255, (value * 255 + color.a / 2) / color.a)) }
            return [unpremultiply(color.r), unpremultiply(color.g), unpremultiply(color.b), UInt8(color.a)]
        }

        var indices = [UInt8](repeating: 0, count: pixelCount)
        pixels.data.withUnsafeBufferPointer { data in
            indices.withUnsafeMutableBufferPointer { indices in
                for pixel in 0..<pixelCount {
                    let offset = pixel * 4
                    let key = (Int(data[offset]) >> 3) << 15 | (Int(data[offset + 1]) >> 3) << 10
                        | (Int(data[offset + 2]) >> 3) << 5 | (Int(data[offset + 3]) >> 3)
                    indices[pixel] = remap[Int(lookup[key])]
                }
            }
        }
        return (palette, indices)
    }

    // MARK: PNG encoding

    static func encodePNG(width: Int, height: Int, palette: [[UInt8]], indices: [UInt8]) throws -> Data {
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var header = Data()
        header += bigEndian(UInt32(width))
        header += bigEndian(UInt32(height))
        header += Data([8, 3, 0, 0, 0]) // 8-bit, indexed, deflate, adaptive filtering, no interlace
        png += chunk("IHDR", header)
        png += chunk("sRGB", Data([0]))
        png += chunk("PLTE", Data(palette.flatMap { $0.prefix(3) }))
        if let lastTransparent = palette.lastIndex(where: { $0[3] < 255 }) {
            png += chunk("tRNS", Data(palette[...lastTransparent].map { $0[3] }))
        }
        var raw = Data(capacity: (width + 1) * height)
        indices.withUnsafeBufferPointer { buffer in
            for row in 0..<height {
                raw.append(0)
                raw.append(contentsOf: buffer[(row * width)..<((row + 1) * width)])
            }
        }
        guard let deflated = try? (raw as NSData).compressed(using: .zlib) as Data else {
            throw GeneralToolFailure("Could not finish the PNG image.")
        }
        var zlib = Data([0x78, 0xDA])
        zlib += deflated
        zlib += bigEndian(adler32(raw))
        png += chunk("IDAT", zlib)
        png += chunk("IEND", Data())
        return png
    }

    private static func chunk(_ type: String, _ body: Data) -> Data {
        let typeData = Data(type.utf8)
        return bigEndian(UInt32(body.count)) + typeData + body + bigEndian(CRC32.checksum(typeData + body))
    }

    static func bigEndian(_ value: UInt32) -> Data {
        Data([UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }

    static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        data.withUnsafeBytes { buffer in
            var index = 0
            let count = buffer.count
            while index < count {
                let end = min(index + 5552, count)
                while index < end {
                    a += UInt32(buffer[index])
                    b += a
                    index += 1
                }
                a %= 65521
                b %= 65521
            }
        }
        return b << 16 | a
    }
}
