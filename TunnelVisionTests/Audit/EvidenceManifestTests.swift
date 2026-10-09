import CryptoKit
import Foundation
import Shared
import XCTest

/// Tests del manifiesto: que el digest es el SHA-256 de los bytes que se escriben, qué lista de
/// ficheros se rechaza y que la captura, que no pasa por memoria, entra con el suyo.
final class EvidenceManifestTests: XCTestCase {

    private typealias Fixtures = FindingFixtures

    private static let exportedAt = Fixtures.start.addingTimeInterval(7_200)
    private static let digest = String(repeating: "0123456789abcdef", count: 4)

    private func entry(_ name: String, sha256: String = digest) -> EvidenceManifest.Entry {
        EvidenceManifest.Entry(name: name, byteCount: 3, sha256: sha256)
    }

    private func makeManifest(_ entries: [EvidenceManifest.Entry]) throws -> EvidenceManifest {
        try EvidenceManifest(sessionID: 7, exportedAt: Self.exportedAt, entries: entries)
    }

    private func assertRefused(
        _ entries: [EvidenceManifest.Entry],
        _ expected: EvidenceManifestError,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try makeManifest(entries), line: line) { error in
            XCTAssertEqual(error as? EvidenceManifestError, expected, line: line)
        }
    }

    // Vectores de FIPS 180-2: el de la cadena vacía y el de «abc».

    func testTheDigestIsTheSHA256OfTheBytes() {
        XCTAssertEqual(
            EvidenceManifest.sha256(of: Data()),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        XCTAssertEqual(
            EvidenceManifest.sha256(of: Data("abc".utf8)),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testADigestFedInPiecesIsWrittenTheSameWay() {
        var hasher = SHA256()
        hasher.update(data: Data("a".utf8))
        hasher.update(data: Data("bc".utf8))

        XCTAssertEqual(EvidenceManifest.hex(hasher.finalize()), EvidenceManifest.sha256(of: Data("abc".utf8)))
    }

    func testAnEntryOfAFileInMemoryCarriesItsSizeAndDigest() {
        let entry = EvidenceManifest.Entry(EvidenceFile(name: "flows.csv", data: Data("abc".utf8)))

        XCTAssertEqual(entry.name, "flows.csv")
        XCTAssertEqual(entry.byteCount, 3)
        XCTAssertEqual(entry.sha256, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testFilesAreListedByNameWhateverTheOrderGiven() throws {
        let manifest = try makeManifest([entry("session.json"), entry("capture.pcap"), entry("flows.json")])

        XCTAssertEqual(manifest.files.map(\.name), ["capture.pcap", "flows.json", "session.json"])
        XCTAssertEqual(manifest.format, "tunnelvision.evidence.manifest")
        XCTAssertEqual(manifest.formatVersion, 1)
        XCTAssertEqual(manifest.sessionID, 7)
        XCTAssertEqual(manifest.exportedAt, Self.exportedAt)
        XCTAssertEqual(manifest.algorithm, "SHA-256")
    }

    func testAListThatCannotBeAManifestIsRefused() {
        assertRefused([], .noFiles)
        assertRefused([entry("")], .invalidFileName(""))
        assertRefused([entry(".")], .invalidFileName("."))
        assertRefused([entry("..")], .invalidFileName(".."))
        assertRefused([entry("../session.json")], .invalidFileName("../session.json"))
        assertRefused([entry("sub/flows.json")], .invalidFileName("sub/flows.json"))
        assertRefused([entry("flows.json"), entry("flows.json")], .duplicateFileName("flows.json"))
        assertRefused([entry("flows.json"), entry("manifest.json")], .listsItself)
    }

    func testADigestThatIsNotOneIsRefused() {
        assertRefused([entry("a", sha256: "")], .invalidDigest(fileName: "a"))
        assertRefused([entry("a", sha256: String(Self.digest.dropLast()))], .invalidDigest(fileName: "a"))
        assertRefused([entry("a", sha256: Self.digest.uppercased())], .invalidDigest(fileName: "a"))
        assertRefused([entry("a", sha256: String(repeating: "g", count: 64))], .invalidDigest(fileName: "a"))
        // 64 caracteres que no son 64 bytes: cifras de otro alfabeto no son hexadecimal.
        assertRefused([entry("a", sha256: String(repeating: "٣", count: 64))], .invalidDigest(fileName: "a"))
    }

    func testTheManifestOfABundleCoversItsDocumentsAndWhatIsWrittenApart() throws {
        let bundle = try EvidenceBundle(
            project: try Fixtures.project(),
            session: Fixtures.session(inspection: InspectionConditions(inspectionEnabled: false, caTrusted: false)),
            markers: [],
            flows: [Fixtures.flow(id: 1, streamOpening: .tlsHandshake)],
            catalogue: try RequirementCatalogueLibrary.catalogue(
                identifier: RequirementCatalogueLibrary.defaultIdentifier
            ),
            exportedWith: "1.1 (4)",
            exportedAt: Self.exportedAt
        )
        let files = try bundle.documentFiles()
        let capture = EvidenceManifest.Entry(name: "capture.pcap", byteCount: 4_096, sha256: Self.digest)
        let manifest = try bundle.manifest(of: files, adding: [capture])

        XCTAssertEqual(
            manifest.files.map(\.name),
            ["capture.pcap", "findings.json", "flows.csv", "flows.json", "session.json"]
        )
        XCTAssertEqual(manifest.sessionID, 7)
        XCTAssertEqual(manifest.exportedAt, Self.exportedAt)
        for file in files {
            let listed = try XCTUnwrap(manifest.files.first { $0.name == file.name })
            XCTAssertEqual(listed.byteCount, file.data.count)
            XCTAssertEqual(listed.sha256, EvidenceManifest.sha256(of: file.data))
        }
        XCTAssertEqual(manifest.files.first, capture)
    }

    func testTheManifestIsAFileOfTheBundleThatDoesNotListItself() throws {
        let file = try makeManifest([entry("flows.json"), entry("session.json")]).file()
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: file.data) as? [String: Any])

        XCTAssertEqual(file.name, "manifest.json")
        XCTAssertEqual(json["algorithm"] as? String, "SHA-256")
        XCTAssertEqual(json["exportedAt"] as? String, "2026-09-21T16:13:20.000Z")
        let files = try XCTUnwrap(json["files"] as? [[String: Any]])
        XCTAssertEqual(files.map { $0["name"] as? String }, ["flows.json", "session.json"])
        XCTAssertEqual(files.first?["byteCount"] as? Int, 3)
        XCTAssertEqual(files.first?["sha256"] as? String, Self.digest)
    }
}
