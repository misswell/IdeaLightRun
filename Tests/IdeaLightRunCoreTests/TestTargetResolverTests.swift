import XCTest
@testable import IdeaLightRunCore

/// M5: JUnit 目标 → 精确测试类筛选。包 / 目录 / 整个模块必须展开，
/// 否则 Maven 的 `-pl -am` 会把上游模块的测试一起跑起来。
final class TestTargetResolverTests: XCTestCase {
    private let fm = FileManager.default
    private var module: URL!

    override func setUpWithError() throws {
        module = fm.temporaryDirectory
            .appendingPathComponent("lr-test-discovery-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try write("com/example/AppTest.java", """
        package com.example;

        import org.junit.jupiter.api.Test;

        public class AppTest {
            @Test
            void works() {}
        }
        """)
        try write("com/example/sub/OtherTest.kt", """
        package com.example.sub

        import org.junit.jupiter.api.Test

        internal class OtherTest {
            @Test
            fun works() {}
        }
        """)
        try write("com/example/Helper.java", """
        package com.example;

        final class Helper {}
        """)
        try write("com/example/SlowSpec.groovy", """
        package com.example

        import spock.lang.Specification

        class SlowSpec extends Specification {
        }
        """)
    }

    override func tearDown() {
        try? fm.removeItem(at: module)
    }

    private func write(_ relativePath: String, _ content: String) throws {
        let url = module.appendingPathComponent("src/test/java/\(relativePath)")
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func resolve(_ target: JUnitRunOptions.Target) throws -> [String] {
        try TestTargetResolver.resolve(
            target,
            moduleDirectory: module,
            projectRoot: module,
            environment: [:]
        )
    }

    func testDiscoversTopLevelTestsOnly() throws {
        XCTAssertEqual(try resolve(.all), [
            "com.example.AppTest",
            "com.example.SlowSpec",
            "com.example.sub.OtherTest",
        ])
    }

    func testPackageMatchesSubpackages() throws {
        XCTAssertEqual(
            try resolve(.package("com.example")),
            ["com.example.AppTest", "com.example.SlowSpec", "com.example.sub.OtherTest"]
        )
        XCTAssertEqual(try resolve(.package("com.example.sub")), ["com.example.sub.OtherTest"])
    }

    func testUnknownPackageFailsWithNoMatchingTests() {
        XCTAssertThrowsError(try resolve(.package("com.example.missing"))) { error in
            guard case IdeaLightRunError.noMatchingTests = error else {
                return XCTFail("期望 noMatchingTests，实际 \(error)")
            }
        }
    }

    func testDirectoryTargetResolvesModuleMacro() throws {
        XCTAssertEqual(
            try resolve(.directory("$MODULE_DIR$/src/test/java/com/example/sub")),
            ["com.example.sub.OtherTest"]
        )
    }

    func testMissingDirectoryFailsClosed() {
        XCTAssertThrowsError(try resolve(.directory("$MODULE_DIR$/src/test/java/ghost"))) { error in
            guard case IdeaLightRunError.invalidConfiguration = error else {
                return XCTFail("期望 invalidConfiguration，实际 \(error)")
            }
        }
    }

    func testPatternExpandsWildcards() throws {
        XCTAssertEqual(
            try resolve(.patterns(["com.example.*Test"])),
            ["com.example.AppTest", "com.example.sub.OtherTest"]
        )
        XCTAssertEqual(
            try resolve(.patterns(["com.example.AppTest#works"])),
            ["com.example.AppTest#works"]
        )
    }

    func testPatternWithoutMatchesFailsClosed() {
        XCTAssertThrowsError(try resolve(.patterns(["*.GhostTest"]))) { error in
            guard case IdeaLightRunError.noMatchingTests = error else {
                return XCTFail("期望 noMatchingTests，实际 \(error)")
            }
        }
    }

    func testTagsAndUniqueIdAreExplicitlyUnsupported() {
        XCTAssertThrowsError(try resolve(.tags(["slow"]))) { error in
            guard case IdeaLightRunError.unsupportedConfiguration = error else {
                return XCTFail("期望 unsupportedConfiguration，实际 \(error)")
            }
        }
        XCTAssertThrowsError(try resolve(.uniqueId("[engine:junit]/[class:com.example.AppTest]"))) { error in
            guard case IdeaLightRunError.unsupportedConfiguration = error else {
                return XCTFail("期望 unsupportedConfiguration，实际 \(error)")
            }
        }
    }
}
