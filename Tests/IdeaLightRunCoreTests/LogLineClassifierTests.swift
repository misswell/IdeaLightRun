import XCTest
@testable import IdeaLightRunCore

/// §P0-11：控制台对齐 IDEA 的内容识别——Spring Boot（Logback）把堆栈写进
/// stdout，只按流着色时整段异常栈都是白色，报错看不出来。
final class LogLineClassifierTests: XCTestCase {
    private func kind(_ text: String, stream: LogStream = .stdout) -> LogLineKind {
        LogLineClassifier.kind(stream: stream, text: text)
    }

    func testStackFrameWithLogbackSuffixIsFrame() {
        XCTAssertEqual(kind("\tat org.springframework.web.method.support.InvocableHandlerMethod.doInvoke(InvocableHandlerMethod.java:205) ~[spring-web-5.3.39.jar:5.3.39]"), .frame)
    }

    func testIndentedSpaceFrameIsFrame() {
        XCTAssertEqual(kind("    at javax.servlet.http.HttpServlet.service(HttpServlet.java:626) [tomcat-embed-core-9.0.37.jar:9.0.37]"), .frame)
    }

    func testKotlinFrameIsFrame() {
        XCTAssertEqual(kind("\tat com.example.Foo$invoke$1.apply(Foo.kt:12)"), .frame)
    }

    func testMoreAndCommonFramesOmittedAreFrames() {
        XCTAssertEqual(kind("\t... 53 common frames omitted"), .frame)
        XCTAssertEqual(kind("\t... 2 more"), .frame)
    }

    func testExceptionHeaderAndCausedByAreErrors() {
        XCTAssertEqual(kind("java.lang.NullPointerException: boom"), .error)
        XCTAssertEqual(kind("org.springframework.web.util.NestedServletException: Request processing failed"), .error)
        XCTAssertEqual(kind("\tCaused by: java.lang.IllegalStateException: later"), .error)
        XCTAssertEqual(kind("\tSuppressed: java.io.IOException: cleanup"), .error)
    }

    func testSpringBootErrorLogLevelLineIsError() {
        let line = "2026-10-16 21:56:12 ERROR 12 --- [nio-8080-exec-1] o.a.c.c.C.[.[.[/] : Servlet.service() threw exception"
        XCTAssertEqual(kind(line), .error)
    }

    func testLowercaseErrorsWordIsNormal() {
        XCTAssertEqual(kind("Compilation finished: 0 errors, 0 warnings"), .normal)
    }

    func testEnglishSentenceStartingWithAtIsNotFrame() {
        XCTAssertEqual(kind("at least one (attempt) was made"), .normal)
    }

    func testErrorHandlerWordIsNormal() {
        XCTAssertEqual(kind("ErrorHandler initialized with 2 rules"), .normal)
    }

    func testPlainInfoLineIsNormal() {
        XCTAssertEqual(kind("INFO Tom started on port(s) 8080 (http) with context path ''"), .normal)
    }

    func testStderrIsAlwaysErrorEvenWhenItLooksLikeFrame() {
        XCTAssertEqual(kind("\tat com.foo.Bar.run(Bar.java:10)", stream: .stderr), .error)
    }

    func testSystemLinesStayNormal() {
        XCTAssertEqual(kind("[IdeaLightRun] 正在监听端口: 8080", stream: .system), .normal)
        XCTAssertEqual(kind("java.lang.Exception in build output", stream: .system), .normal)
    }

    func testLogLineCarriesKindComputedAtInit() {
        XCTAssertEqual(LogLine(stream: .stdout, text: "\tat com.foo.Bar.run(Bar.java:10)").kind, .frame)
        XCTAssertEqual(LogLine(stream: .stderr, text: "anything").kind, .error)
    }
}
