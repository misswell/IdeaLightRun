import XCTest
@testable import IdeaLightRunCore

/// §4.3: `.env` 解释。IdeaLightRun 不启动 shell，所以赋值语义必须由自己实现，
/// 且不能把带值的内容写进诊断日志（§17）。
final class DotEnvParserTests: XCTestCase {
    func testCommonSyntaxes() throws {
        let content = """
        # comment line

        A=1
        B="hello world"
        C='hello world'
        export D=value
        E=keep # cut the inline comment
        F=no#hash-inside
        EMPTY=
          G=indented
        """
        let result = DotEnvParser.parse(content)
        XCTAssertEqual(result.values["A"], "1")
        XCTAssertEqual(result.values["B"], "hello world")
        XCTAssertEqual(result.values["C"], "hello world")
        XCTAssertEqual(result.values["D"], "value")
        XCTAssertEqual(result.values["E"], "keep")
        XCTAssertEqual(result.values["F"], "no#hash-inside")
        XCTAssertEqual(result.values["EMPTY"], "")
        XCTAssertEqual(result.values["G"], "indented")
    }

    func testExpansionAndEscapes() throws {
        let content = """
        BASE=/opt/app
        DERIVED=${BASE}/bin
        SHELLISH=$BASE/bin
        QUOTED="${BASE}/bin"
        LITERAL='${BASE}/bin'
        ESCAPED="line\\nbreak\\ttab\\$notvar"
        MISSING=${NOT_DEFINED}/keep
        """
        let result = DotEnvParser.parse(content, environment: ["BASE": "/from/parent"])
        XCTAssertEqual(result.values["DERIVED"], "/opt/app/bin")
        // 裸值与双引号里都展开 $VAR 简写
        XCTAssertEqual(result.values["SHELLISH"], "/opt/app/bin")
        XCTAssertEqual(result.values["QUOTED"], "/opt/app/bin")
        // 单引号是字面量
        XCTAssertEqual(result.values["LITERAL"], "${BASE}/bin")
        XCTAssertEqual(result.values["ESCAPED"], "line\nbreak\ttab$notvar")
        // 未定义的引用保留原文，用户看得出哪个没展开
        XCTAssertEqual(result.values["MISSING"], "${NOT_DEFINED}/keep")
    }

    func testExpansionFallsBackToProvidedEnvironment() {
        let result = DotEnvParser.parse("A=$FROM_PARENT", environment: ["FROM_PARENT": "parent-value"])
        XCTAssertEqual(result.values["A"], "parent-value")
    }

    /// §17: 无法识别的行只记行号，内容（可能是 Secret）不进诊断。
    func testIgnoredLinesRecordNumbersOnly() {
        let result = DotEnvParser.parse("A=1\nthis-is-not-an-assignment\n1BAD=x\n\n# comment")
        XCTAssertEqual(result.ignoredLineNumbers, [2, 3])
        XCTAssertFalse(result.values.keys.contains("1BAD"))
        XCTAssertTrue(result.ignoredLineNumbers.allSatisfy { $0 > 0 })
        XCTAssertEqual(DotEnvParser.parse("A=1\n# c\n\nB=2").ignoredLineNumbers, [])
    }

    /// 同名变量后写覆盖前写，与 shell source 的顺序语义一致。
    func testLaterAssignmentWins() {
        XCTAssertEqual(DotEnvParser.parse("A=first\nA=second").values["A"], "second")
    }
}
