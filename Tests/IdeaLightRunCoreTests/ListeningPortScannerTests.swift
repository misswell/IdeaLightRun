import XCTest
@testable import IdeaLightRunCore

final class ListeningPortScannerTests: XCTestCase {
    func testParseCollectsPortsFromAddressLinesAndSorts() {
        let output = """
        p1234
        cjava
        n*:8080
        n127.0.0.1:9000
        n[::]:9229
        n[fe80::1%en0]:5353
        """
        XCTAssertEqual(ListeningPortScanner.parse(output), [5353, 8080, 9000, 9229])
    }

    func testParseDeduplicatesSamePortOnDifferentAddresses() {
        XCTAssertEqual(ListeningPortScanner.parse("n*:8080\nn0.0.0.0:8080\nn*:9999\n"), [8080, 9999])
    }

    func testParseIgnoresNonAddressLinesAndJunk() {
        XCTAssertEqual(ListeningPortScanner.parse("p1\ncjava\nnlocalhost:notaport\nn\nx*:80\n"), [])
        XCTAssertEqual(ListeningPortScanner.parse(""), [])
    }
}
