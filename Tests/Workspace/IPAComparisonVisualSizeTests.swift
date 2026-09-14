import XCTest
import CoreGraphics
import ImageIO
@testable import ipaverse

final class IPAComparisonVisualSizeTests: XCTestCase {
    private func png(_ bytes: [UInt8], width: Int, height: Int) throws -> Data {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func testPixelDifferenceIncludesAlphaAndPreservesMaskPosition() throws {
        let red: [UInt8] = [255, 0, 0, 255], clear: [UInt8] = [0, 0, 0, 0]
        let a = try png(red + red + red + red, width: 2, height: 2)
        let b = try png(clear + red + red + red, width: 2, height: 2)
        XCTAssertEqual(Array(try IPAComparisonImageDiff.decode(b).rgba.prefix(4)), clear)
        let result = try IPAComparisonImageDiff.compare(before: a, after: b)
        XCTAssertEqual(result.changedPixels, 1)
        XCTAssertEqual(result.comparedPixels, 4)
        XCTAssertEqual(result.fraction, 0.25)
        let mask = try IPAComparisonImageDiff.decode(result.png)
        XCTAssertEqual(Array(mask.rgba.prefix(4)), [255, 30, 180, 255])
        XCTAssertEqual(try IPAComparisonImageDiff.compare(before: b, after: a).changedPixels, 1)
        XCTAssertEqual(try IPAComparisonImageDiff.compare(before: a, after: a).changedPixels, 0)
    }

    func testTransparentRGBIsIgnoredAndExtentChangesAreCounted() throws {
        let a = try png([255, 0, 0, 0], width: 1, height: 1)
        let b = try png([0, 255, 0, 0], width: 1, height: 1)
        XCTAssertEqual(try IPAComparisonImageDiff.compare(before: a, after: b).changedPixels, 0)
        let wider = try png([UInt8](repeating: 0, count: 8), width: 2, height: 1)
        let taller = try png([UInt8](repeating: 0, count: 8), width: 1, height: 2)
        let result = try IPAComparisonImageDiff.compare(before: wider, after: taller)
        XCTAssertEqual(result.comparedPixels, 3) // union, not the empty bottom-right corner
        XCTAssertEqual(result.changedPixels, 2)
        XCTAssertThrowsError(try IPAComparisonImageDiff.compare(before: Data(), after: a))
        let oversized = try png([UInt8](repeating: 0, count: 513 * 4), width: 513, height: 1)
        XCTAssertThrowsError(try IPAComparisonImageDiff.compare(before: oversized, after: a))
    }

    func testSizeGroupsUseExclusiveOwnershipAndKeepOffsettingChanges() throws {
        let files = [
            IPAComparisonFileSize(source: "App", before: 100, after: 120),
            IPAComparisonFileSize(source: "Assets.car", before: 60, after: 40),
            IPAComparisonFileSize(source: "PlugIns/Share.appex/Share", before: 30, after: 35),
            IPAComparisonFileSize(source: "PlugIns/Share.appex/Frameworks/Kit.framework/Kit", before: 50, after: 70),
            IPAComparisonFileSize(source: "Resources.bundle/Added", before: nil, after: 10),
            IPAComparisonFileSize(source: "old", before: 15, after: nil),
            IPAComparisonFileSize(source: "empty", before: nil, after: 0)
        ]
        let groups = IPAComparisonSizeGroup.groups(files)
        XCTAssertEqual(groups.reduce(0) { $0 + $1.before }, 255)
        XCTAssertEqual(groups.reduce(0) { $0 + $1.after }, 275)
        XCTAssertEqual(groups.first { $0.id == "PlugIns/Share.appex" }?.delta, 5)
        XCTAssertEqual(groups.first { $0.id.hasSuffix("Kit.framework") }?.delta, 20)
        let main = try XCTUnwrap(groups.first { $0.id == "." })
        XCTAssertEqual(main.growth, 20)
        XCTAssertEqual(main.reduction, -35)
        XCTAssertEqual(files.last?.kind, "Added")
        XCTAssertEqual(files.last?.swapped.kind, "Removed")
        let balanced = IPAComparisonSizeGroup.groups(Array(files.prefix(2)))
        XCTAssertEqual(balanced.first?.delta, 0)
        XCTAssertEqual(balanced.first?.changedCount, 2)
        XCTAssertEqual(IPAComparisonSizeGroup.groups(files.map(\.swapped)).reduce(0) { $0 + $1.delta }, -20)
        let decoded = try JSONDecoder().decode([IPAComparisonFileSize].self, from: JSONEncoder().encode(files))
        XCTAssertEqual(decoded, files)
    }
}
