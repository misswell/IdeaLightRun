import XCTest
@testable import IdeaLightRunCore

final class CommandLineTokenizerTests: XCTestCase {
    func assertTokens(_ input: String, _ expected: [String], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(CommandLineTokenizer.tokenize(input), expected, file: file, line: line)
    }

    /// §12 基础示例
    func testSimpleVMOption() {
        assertTokens("-Xmx1024m -Dname=\"hello world\"", ["-Xmx1024m", "-Dname=hello world"])
    }

    func testSingleQuotes() {
        assertTokens("--name 'hello world'", ["--name", "hello world"])
    }

    func testQuotedPath() {
        assertTokens("-Dpath=\"/Users/a b/test\"", ["-Dpath=/Users/a b/test"])
    }

    /// §72 参数测试集
    func testSpecCases() {
        assertTokens("-Dfoo=bar", ["-Dfoo=bar"])
        assertTokens("-Dfoo=\"hello world\"", ["-Dfoo=hello world"])
        assertTokens("--name \"hello world\"", ["--name", "hello world"])
        assertTokens("--spring.profiles.active=dev", ["--spring.profiles.active=dev"])
        assertTokens("-Dpath=\"/Users/a b/test\"", ["-Dpath=/Users/a b/test"])
    }

    func testEmptyInput() {
        assertTokens("", [])
        assertTokens("   \t ", [])
    }

    func testAdjacentQuotedSegmentsJoin() {
        assertTokens("ab\"c d\"e", ["abc de"])
        assertTokens("-Xmx\"1024\"m", ["-Xmx1024m"])
    }

    func testEmptyQuotedToken() {
        assertTokens("a '' b", ["a", "", "b"])
    }

    func testBackslashEscapeOutsideQuotes() {
        assertTokens("a\\ b", ["a b"])
        assertTokens("a\\\"b", ["a\"b"])
    }

    func testBackslashInsideDoubleQuotes() {
        assertTokens("\"line\\\"quote\"", ["line\"quote"])
        assertTokens("\"back\\\\slash\"", ["back\\slash"])
        // 双引号内 \$ 保留为 $
        assertTokens("\"cost \\$5\"", ["cost $5"])
    }

    func testSingleQuotesAreLiteral() {
        assertTokens("'a \"b\" \\c'", ["a \"b\" \\c"])
    }

    func testUnterminatedQuoteIsTolerated() {
        assertTokens("\"open ended", ["open ended"])
        assertTokens("'single", ["single"])
    }

    func testMultipleWhitespace() {
        assertTokens("  -a   -b\t-c  ", ["-a", "-b", "-c"])
    }
}
