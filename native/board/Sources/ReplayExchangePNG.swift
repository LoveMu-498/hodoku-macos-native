// Copyright (C) 2026 HoDoKu contributors. GPL-3.0-or-later.
import CoreGraphics
import Foundation
import ImageIO
import zlib

enum ReplayExchangePNG {
    static let byteLimit = 8 * 1024 * 1024
    static let signature = Data([137, 80, 78, 71, 13, 10, 26, 10])

    static func word(_ bytes: Data, _ index: Int) -> Int {
        bytes[index..<index + 4].reduce(0) { ($0 << 8) | Int($1) }
    }
    static func wordBytes(_ n: Int) -> Data {
        Data((0..<4).reversed().map { UInt8(truncatingIfNeeded: n >> (8 * $0)) })
    }

    static func validate(_ bytes: Data) throws {
        try exchangeRequire(bytes.count <= byteLimit && bytes.starts(with: signature), "PNG 文件头错误")
        var at = 8
        var width = 0
        var height = 0
        var ended = false
        var compressed = Data()
        while at < bytes.count {
            try exchangeRequire(bytes.count - at >= 12, "PNG 块被截断")
            let length = word(bytes, at)
            try exchangeRequire(length <= bytes.count - at - 12, "PNG 块长度错误")
            let tag = word(bytes, at + 4)
            let checksum = bytes.withUnsafeBytes { raw in
                crc32(0, raw.bindMemory(to: UInt8.self).baseAddress! + at + 4, UInt32(length + 4))
            }
            try exchangeRequire(Int(checksum) == word(bytes, at + 8 + length), "PNG 校验失败")
            switch tag {
            case 0x4948_4452:
                try exchangeRequire(at == 8 && length == 13, "PNG IHDR 错误")
                width = word(bytes, at + 8)
                height = word(bytes, at + 12)
                try exchangeRequire(
                    (1...4096).contains(width) && (1...4096).contains(height)
                        && bytes[at + 16..<at + 21].elementsEqual([8, 6, 0, 0, 0]), "PNG 尺寸或颜色模式错误")
            case 0x4944_4154:
                try exchangeRequire(width > 0, "PNG 数据顺序错误")
                compressed.append(bytes[at + 8..<at + 8 + length])
            case 0x4945_4E44:
                try exchangeRequire(length == 0 && at + 12 == bytes.count, "PNG 尾部错误")
                ended = true
            default: throw ReplayExchangeError("PNG 含不支持的块")
            }
            at += length + 12
        }
        try exchangeRequire(ended && !compressed.isEmpty, "PNG 数据不完整")
        let stride = 1 + width * 4
        let expected = stride * height
        var stream = z_stream()
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw ReplayExchangeError("PNG 解压失败")
        }
        defer { inflateEnd(&stream) }
        try compressed.withUnsafeBytes { raw in
            stream.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: UInt8.self).baseAddress!)
            stream.avail_in = UInt32(raw.count)
            var buffer = [UInt8](repeating: 0, count: 16_384)
            var total = 0
            while true {
                let status = buffer.withUnsafeMutableBufferPointer { out in
                    stream.next_out = out.baseAddress
                    stream.avail_out = UInt32(out.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let n = buffer.count - Int(stream.avail_out)
                try exchangeRequire(
                    (status == Z_STREAM_END || (status == Z_OK && n > 0)) && n <= expected - total,
                    "PNG 像素长度或压缩流错误")
                let first = (stride - total % stride) % stride
                for i in Swift.stride(from: first, to: n, by: stride) {
                    try exchangeRequire(buffer[i] <= 4, "PNG 行滤镜错误")
                }
                total += n
                if status == Z_STREAM_END {
                    try exchangeRequire(total == expected && stream.avail_in == 0, "PNG 压缩流尾部错误")
                    break
                }
            }
        }
    }

    // ImageIO may emit color profiles, RGB or multiple ancillary chunks. Create
    // the negotiated RGBA8 carrier directly from the frozen pixels.
    static func carrier(from source: Data) throws -> Data {
        if (try? validate(source)) != nil { return source }
        guard let input = CGImageSourceCreateWithData(source as CFData, nil),
            let props = CGImageSourceCopyPropertiesAtIndex(input, 0, nil) as? [CFString: Any],
            let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
            (1...4096).contains(w), (1...4096).contains(h),
            let image = CGImageSourceCreateImageAtIndex(input, 0, nil)
        else { throw ReplayExchangeError("无法读取冻结图像") }
        let stride = w * 4
        let row = stride + 1
        var raw = Data(count: row * h)
        try raw.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) in
            let info = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            var bitmap = Data(count: stride * h)
            try bitmap.withUnsafeMutableBytes { (pixels: UnsafeMutableRawBufferPointer) in
                guard
                    let ctx = CGContext(
                        data: pixels.baseAddress, width: w, height: h, bitsPerComponent: 8,
                        bytesPerRow: stride, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)
                else {
                    throw ReplayExchangeError("无法转换冻结图像")
                }
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                for y in 0..<h {
                    let src = pixels.baseAddress! + y * stride
                    let dst = out.baseAddress! + y * row + 1
                    dst.copyMemory(from: src, byteCount: stride)
                    let p = dst.assumingMemoryBound(to: UInt8.self)
                    for x in Swift.stride(from: 0, to: stride, by: 4) where p[x + 3] > 0 && p[x + 3] < 255 {
                        let alpha = Int(p[x + 3])
                        for channel in 0..<3 {
                            p[x + channel] = UInt8(clamping: (Int(p[x + channel]) * 255 + alpha / 2) / alpha)
                        }
                    }
                }
            }
        }
        var size = compressBound(UInt(raw.count))
        var compressed = Data(count: Int(size))
        let status = compressed.withUnsafeMutableBytes { out in
            raw.withUnsafeBytes { src in
                compress2(
                    out.bindMemory(to: UInt8.self).baseAddress!, &size,
                    src.bindMemory(to: UInt8.self).baseAddress!, UInt(src.count), Z_DEFAULT_COMPRESSION)
            }
        }
        try exchangeRequire(status == Z_OK && size <= byteLimit - 57, "冻结图像超过交换大小")
        compressed.count = Int(size)
        var result = signature
        func chunk(_ tag: String, _ contents: Data) {
            let content = Data(tag.utf8) + contents
            result.append(wordBytes(contents.count))
            result.append(content)
            result.append(
                wordBytes(
                    Int(
                        content.withUnsafeBytes { raw in
                            crc32(0, raw.bindMemory(to: UInt8.self).baseAddress!, UInt32(raw.count))
                        })))
        }
        chunk("IHDR", wordBytes(w) + wordBytes(h) + Data([8, 6, 0, 0, 0]))
        chunk("IDAT", compressed)
        chunk("IEND", Data())
        return result
    }
}
