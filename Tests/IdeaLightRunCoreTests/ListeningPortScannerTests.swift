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

    /// 端到端：在本进程里真开一个 LISTEN socket（端口 0 由内核分配），
    /// lsof 必须能探到它。GUI 里「端口不显示」既可能是探测断了也可能是布局
    /// 挤没了，这个测试钉住探测这一半。
    func testListeningPortsFindsRealLocalListener() throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        try XCTUnwrap(fd >= 0, "socket 创建失败")
        defer { Darwin.close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr = in_addr(s_addr: INADDR_ANY)
        addr.sin_port = 0  // 让内核挑端口
        var bindAddress = sockaddr()
        withUnsafeBytes(of: &addr) { raw in
            _ = withUnsafeMutableBytes(of: &bindAddress) { target in
                raw.copyBytes(to: target)
            }
        }
        let bindResult = Darwin.bind(fd, &bindAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
        XCTAssertEqual(bindResult, 0, "bind 失败 errno=\(errno)")
        XCTAssertEqual(Darwin.listen(fd, 1), 0, "listen 失败 errno=\(errno)")

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        XCTAssertEqual(
            Darwin.getsockname(fd, &bindAddress, &length), 0,
            "getsockname 失败 errno=\(errno)"
        )
        // sin_port 是网络字节序（大端），sockaddr 的第 3、4 字节
        let portBytes = withUnsafeBytes(of: &bindAddress) { raw in
            (raw[raw.startIndex + 2], raw[raw.startIndex + 3])
        }
        let port = (Int(portBytes.0) << 8) | Int(portBytes.1)
        try XCTUnwrap(port > 0, "端口分配异常：\(port)")

        let ports = ListeningPortScanner.listeningPorts(pid: Int32(getpid()))
        XCTAssertTrue(
            ports.contains(port),
            "lsof 没探到本进程刚开的监听端口 \(port)，实际：\(ports)"
        )
    }
}
