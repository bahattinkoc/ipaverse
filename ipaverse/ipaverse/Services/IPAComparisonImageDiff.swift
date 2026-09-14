import Foundation
import CoreGraphics
import ImageIO

enum IPAComparisonImageDiff {
    struct Result: Sendable {
        let png: Data
        let width: Int
        let height: Int
        let changedPixels: Int
        let comparedPixels: Int
        var fraction: Double { Double(changedPixels) / Double(max(1, comparedPixels)) }
    }
    struct Pixels {
        let width: Int
        let height: Int
        let rgba: [UInt8]
    }

    // Both inputs are bounded previews, aligned at their top-left pixel without
    // stretching. Compare premultiplied sRGB, including alpha; transparent RGB
    // payload differences are visually irrelevant. Pixels outside either extent
    // are changes even when the newly added/removed area is transparent.
    static func compare(before: Data, after: Data) throws -> Result {
        let a = try decode(before), b = try decode(after)
        let width = max(a.width, b.width), height = max(a.height, b.height)
        var output = [UInt8](repeating: 0, count: width * height * 4)
        var changed = 0, compared = 0
        for y in 0..<height {
            try Task.checkCancellation()
            for x in 0..<width {
                let inA = x < a.width && y < a.height, inB = x < b.width && y < b.height
                guard inA || inB else { continue }
                compared += 1
                let ai = (y * a.width + x) * 4, bi = (y * b.width + x) * 4
                let differs = !inA || !inB || (0..<4).contains { a.rgba[ai + $0] != b.rgba[bi + $0] }
                let offset = (y * width + x) * 4
                if differs {
                    changed += 1
                    output[offset] = 255; output[offset + 1] = 30; output[offset + 2] = 180; output[offset + 3] = 255
                } else {
                    // Dim unchanged pixels against white so the mask stays legible.
                    let alpha = Int(a.rgba[ai + 3])
                    let luminance = (Int(a.rgba[ai]) + Int(a.rgba[ai + 1]) + Int(a.rgba[ai + 2])) / 3 + 255 - alpha
                    let gray = UInt8(min(255, 170 + luminance / 3))
                    output[offset] = gray; output[offset + 1] = gray; output[offset + 2] = gray; output[offset + 3] = 255
                }
            }
        }
        return Result(png: try encode(output, width: width, height: height), width: width, height: height,
                      changedPixels: changed, comparedPixels: compared)
    }

    static func decode(_ data: Data) throws -> Pixels {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
              width > 0, height > 0, width <= 512, height <= 512,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw failure() }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let success = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard success else { throw failure() }
        return Pixels(width: width, height: height, rgba: rgba)
    }

    private static func encode(_ bytes: [UInt8], width: Int, height: Int) throws -> Data {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                  bytesPerRow: width * 4, space: space,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw failure() }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { throw failure() }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw failure() }
        return output as Data
    }
    private static func failure() -> NSError {
        NSError(domain: "IPAComparisonImageDiff", code: 1, userInfo: [NSLocalizedDescriptionKey: "Preview pixel comparison unavailable"])
    }
}
