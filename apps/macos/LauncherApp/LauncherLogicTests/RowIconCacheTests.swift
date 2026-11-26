import AppKit
import XCTest
@testable import LauncherLogic

final class RowIconCacheTests: XCTestCase {
    /// A solid-colour image backed by a real bitmap (no window server needed).
    private func solid(_ color: NSColor, width: Int, height: Int) -> NSImage {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        color.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(rep)
        return image
    }

    private func bigImage() -> NSImage { solid(.red, width: 512, height: 512) }

    func testRasterizedIsOneSmallRetinaBitmap() {
        let out = RowIconCache.rasterized(bigImage(), points: 32)
        XCTAssertEqual(out.size, NSSize(width: 32, height: 32))
        XCTAssertEqual(out.representations.count, 1)
        let rep = out.representations[0] as? NSBitmapImageRep
        XCTAssertEqual(rep?.pixelsWide, 64)
        XCTAssertEqual(rep?.pixelsHigh, 64)
    }

    func testRasterizedKeepsThePixelsOfTheSource() {
        let out = RowIconCache.rasterized(bigImage(), points: 32)
        let rep = out.representations[0] as? NSBitmapImageRep
        let color = rep?.colorAt(x: 32, y: 32)?.usingColorSpace(.deviceRGB)
        XCTAssertNotNil(color)
        XCTAssertGreaterThan(color?.redComponent ?? 0, 0.8)
        XCTAssertEqual(color?.alphaComponent ?? 0, 1, accuracy: 0.01)
    }

    func testNonSquareImagesAreFittedNotStretched() {
        let wide = solid(.blue, width: 200, height: 100)
        let rep = RowIconCache.rasterized(wide, points: 32).representations[0] as? NSBitmapImageRep
        // Letterboxed: the top row is empty, the middle row is filled.
        XCTAssertEqual(rep?.colorAt(x: 32, y: 2)?.alphaComponent ?? 1, 0, accuracy: 0.01)
        XCTAssertEqual(rep?.colorAt(x: 32, y: 32)?.alphaComponent ?? 0, 1, accuracy: 0.01)
    }

    func testAnIconWithMultipleResolutionsKeepsItsContent() throws {
        let size = NSSize(width: 32, height: 32)
        let icon = NSImage(size: size)
        for pixels in [32, 64] {
            let source = solid(.blue, width: pixels, height: pixels)
            let representation = try XCTUnwrap(source.representations.first)
            representation.size = size
            icon.addRepresentation(representation)
        }

        let output = RowIconCache.rasterized(icon, points: 32)
        XCTAssertEqual(output.representations.count, 1)
        let bitmap = try XCTUnwrap(output.representations.first as? NSBitmapImageRep)
        XCTAssertGreaterThan(bitmap.colorAt(x: 32, y: 32)?.alphaComponent ?? 0, 0.5)
    }

    func testTemplateImagesAreLeftAlone() {
        let template = bigImage()
        template.isTemplate = true
        XCTAssertTrue(RowIconCache.rasterized(template, points: 32) === template)
    }

    func testTheSameKeyReturnsTheSameInstance() {
        let key = "test-\(UUID().uuidString)"
        let first = RowIconCache.image(key: key) { RowIconCache.rasterized(bigImage(), points: 32) }
        let second = RowIconCache.image(key: key) { XCTFail("resolved twice"); return bigImage() }
        XCTAssertTrue(first === second)
    }
}
