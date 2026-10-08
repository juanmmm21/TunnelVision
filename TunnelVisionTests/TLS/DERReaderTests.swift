import Foundation
import XCTest
@testable import Shared

/// Tests del lector de DER: que lee lo que `DER` escribe y que ningún byte que declare de más le
/// hace salirse de lo que tiene.
final class DERReaderTests: XCTestCase {

    private func reader(_ bytes: [UInt8]) -> DERReader {
        DERReader(bytes[...])
    }

    func testReadsAShortFormElement() {
        var reader = reader([0x04, 0x02, 0xAA, 0xBB, 0x05, 0x00])
        let first = reader.element()
        XCTAssertEqual(first?.tag, 0x04)
        XCTAssertEqual(first.map { Array($0.content) }, [0xAA, 0xBB])
        XCTAssertEqual(first.map { Array($0.raw) }, [0x04, 0x02, 0xAA, 0xBB])
        XCTAssertEqual(reader.nextTag, 0x05)
        XCTAssertEqual(reader.element().map { Array($0.content) }, [])
        XCTAssertTrue(reader.isAtEnd)
    }

    func testReadsWhatTheWriterProducesInLongForm() {
        let content = [UInt8](repeating: 0x5A, count: 300)
        var reader = reader(DER.octetString(content))
        XCTAssertEqual(reader.element().map { Array($0.content) }, content)
        XCTAssertTrue(reader.isAtEnd)
    }

    func testAnElementInsideASliceKeepsItsOwnBounds() {
        let bytes: [UInt8] = [0xFF, 0x30, 0x03, 0x02, 0x01, 0x07, 0xFF]
        var outer = DERReader(bytes[1..<6])
        var inner = DERReader(outer.content(tag: DERReader.Tag.sequence) ?? [])
        XCTAssertEqual(inner.content(tag: DERReader.Tag.integer).map(Array.init), [0x07])
        XCTAssertTrue(outer.isAtEnd)
    }

    func testALengthThatDeclaresMoreThanThereIsIsRefused() {
        var short = reader([0x04, 0x05, 0xAA])
        XCTAssertNil(short.element())
        var long = reader([0x04, 0x82, 0x01, 0x00, 0xAA])
        XCTAssertNil(long.element())
    }

    func testAFailedReadDoesNotMoveTheCursor() {
        var reader = reader([0x04, 0x05, 0xAA])
        XCTAssertNil(reader.element())
        XCTAssertEqual(reader.nextTag, 0x04)
    }

    func testIndefiniteLengthIsRefused() {
        var reader = reader([0x30, 0x80, 0x00, 0x00])
        XCTAssertNil(reader.element())
    }

    func testALengthOfMoreThanFourBytesIsRefused() {
        var reader = reader([0x04, 0x85, 0x00, 0x00, 0x00, 0x00, 0x01, 0xAA])
        XCTAssertNil(reader.element())
    }

    func testAHighTagNumberIsRefused() {
        var reader = reader([0x1F, 0x81, 0x00, 0x00])
        XCTAssertNil(reader.element())
    }

    func testATruncatedHeaderIsRefused() {
        var onlyTag = reader([0x30])
        XCTAssertNil(onlyTag.element())
        var cutLength = reader([0x30, 0x82, 0x01])
        XCTAssertNil(cutLength.element())
        var empty = reader([])
        XCTAssertNil(empty.element())
        XCTAssertNil(empty.nextTag)
    }

    func testContentWithTheWrongTagReadsNothing() {
        var reader = reader([0x02, 0x01, 0x07])
        XCTAssertNil(reader.content(tag: DERReader.Tag.sequence))
        XCTAssertEqual(reader.content(tag: DERReader.Tag.integer).map(Array.init), [0x07])
    }
}
