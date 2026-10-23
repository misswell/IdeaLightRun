import XCTest
@testable import IdeaLightRunCore

final class HotReloadWorkspaceTests: XCTestCase {
    private var projectRoot: URL!

    override func setUpWithError() throws {
        projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("hot-reload-workspace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let root = projectRoot!
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    }

    private var sourceRoot: URL { projectRoot.appendingPathComponent("src/main/java", isDirectory: true) }
    private var resourceRoot: URL { projectRoot.appendingPathComponent("src/main/resources", isDirectory: true) }
    private var classesRoot: URL { projectRoot.appendingPathComponent("target/classes", isDirectory: true) }

    private func write(_ relativePath: String, _ contents: String, in root: URL? = nil) throws -> URL {
        let url = (root ?? projectRoot).appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func makeModule() -> ProjectModule {
        ProjectModule(name: "demo", directory: projectRoot)
    }

    private func makeWorkspace(maxFiles: Int = HotReloadWorkspace.defaultMaxFiles) -> HotReloadWorkspace {
        let module = makeModule()
        let target = BuildTarget(
            module: module,
            variant: .maven(module: "demo", includeProvided: false)
        )
        let watch = HotReloadModuleWatch(
            module: module,
            target: target,
            codeRoots: [sourceRoot],
            resourceRoots: [resourceRoot]
        )
        return HotReloadWorkspace(
            projectRoot: projectRoot,
            primaryModule: module,
            primaryTarget: target,
            moduleWatches: [watch],
            outputRoots: [classesRoot],
            maxFiles: maxFiles
        )
    }

    func testSnapshotSeparatesSourcesResourcesClassesAndNestedClassNames() throws {
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resourceRoot, withIntermediateDirectories: true)
        _ = try write("src/main/java/demo/App.java", "class App {}")
        _ = try write("src/main/java/demo/Notes.txt", "not source")
        _ = try write("src/main/resources/application.yml", "server:\n  port: 8080\n")
        _ = try write("target/classes/demo/App.class", "class-bytes")
        _ = try write("target/classes/demo/App$Inner.class", "inner-bytes")
        _ = try write("target/classes/meta.properties", "key=value")
        _ = try write("target/classes/META-INF/versions/9/demo/App.class", "multi-release")
        _ = try write("target/classes/module-info.class", "module-info")

        let snapshot = makeWorkspace().snapshot()
        XCTAssertEqual(snapshot.sources.count, 1)
        XCTAssertTrue(snapshot.sources.keys.contains { $0.hasSuffix("/src/main/java/demo/App.java") })
        XCTAssertEqual(snapshot.sourceResources.count, 1)
        XCTAssertTrue(snapshot.sourceResources.keys.contains { $0.hasSuffix("/src/main/resources/application.yml") })
        XCTAssertEqual(snapshot.outputResources.count, 1)
        XCTAssertTrue(snapshot.outputResources.keys.contains { $0.hasSuffix("/target/classes/meta.properties") })

        let names = Set(snapshot.classNames.values)
        XCTAssertEqual(names, ["demo.App", "demo.App$Inner"])
        XCTAssertFalse(snapshot.truncated)
    }

    func testIgnoredPathsAreNormalizedInsideProjectRootOnly() throws {
        let inside = projectRoot.appendingPathComponent("target/generated").path
        let outside = projectRoot.deletingLastPathComponent()
            .appendingPathComponent("hot-reload-outside-\(UUID().uuidString)").path
        let normalized = HotReloadWorkspace.normalizedIgnoredPaths(
            [" target ", "src/generated", "  ", outside, inside],
            projectRoot: projectRoot
        )
        var expected = [
            projectRoot.appendingPathComponent("target").standardizedFileURL.path,
            projectRoot.appendingPathComponent("src/generated").standardizedFileURL.path
        ]
        expected.append(URL(fileURLWithPath: inside).standardizedFileURL.path)
        XCTAssertEqual(normalized, expected)
    }

    func testRelevanceIncludesAncestorsButNotIgnoredPaths() throws {
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: classesRoot, withIntermediateDirectories: true)
        let module = makeModule()
        let target = BuildTarget(module: module, variant: .maven(module: "demo", includeProvided: false))
        let workspace = HotReloadWorkspace(
            projectRoot: projectRoot,
            primaryModule: module,
            primaryTarget: target,
            moduleWatches: [
                HotReloadModuleWatch(
                    module: module,
                    target: target,
                    codeRoots: [sourceRoot],
                    resourceRoots: []
                )
            ],
            outputRoots: [classesRoot],
            ignoredPaths: [projectRoot.appendingPathComponent("src/main/java/generated").path]
        )

        XCTAssertTrue(workspace.isRelevantPath(sourceRoot.path))
        XCTAssertTrue(
            workspace.isRelevantPath(sourceRoot.appendingPathComponent("demo/App.java").path)
        )
        XCTAssertTrue(
            workspace.isRelevantPath(projectRoot.appendingPathComponent("src/main/java").path),
            "新增文件时 FSEvents 可能只报父目录"
        )
        XCTAssertFalse(
            workspace.isRelevantPath(projectRoot.appendingPathComponent("README.md").path)
        )
        XCTAssertFalse(
            workspace.isRelevantPath(
                projectRoot.appendingPathComponent("src/main/java/generated/Gen.java").path
            )
        )
    }

    func testDiffReportsModifiedAddedRemovedAndSourceChanges() throws {
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        _ = try write("src/main/java/demo/App.java", "class App { int a; }")
        _ = try write("target/classes/demo/App.class", "original-bytes")
        _ = try write("target/classes/demo/Removed.class", "removed-bytes")
        let workspace = makeWorkspace()
        let previous = workspace.snapshot()

        _ = try write("src/main/java/demo/App.java", "class App { int a; int b; }")
        _ = try write("target/classes/demo/App.class", "modified-bytes-longer")
        _ = try write("target/classes/demo/Added.class", "added-bytes")
        try FileManager.default.removeItem(
            at: projectRoot.appendingPathComponent("target/classes/demo/Removed.class")
        )
        let current = workspace.snapshot()
        let diff = current.diff(from: previous)

        XCTAssertEqual(diff.changedSources.count, 1)
        XCTAssertTrue(diff.changedSources[0].path.hasSuffix("/src/main/java/demo/App.java"))
        let changedNames = Set(diff.classChanges.map(\.className))
        XCTAssertEqual(changedNames, ["demo.App", "demo.Added", "demo.Removed"])
        XCTAssertEqual(
            diff.classChanges.first { $0.className == "demo.App" }?.kind,
            .modified
        )
        XCTAssertEqual(
            diff.classChanges.first { $0.className == "demo.Added" }?.kind,
            .added
        )
        XCTAssertEqual(
            diff.classChanges.first { $0.className == "demo.Removed" }?.kind,
            .removed
        )
        XCTAssertEqual(diff.sourceChanges(projectRoot: projectRoot), ["src/main/java/demo/App.java"])
    }

    func testSnapshotCheapReuseKeepsFingerprintWhenMetadataUnchanged() throws {
        _ = try write("target/classes/demo/App.class", "bytes")
        let workspace = makeWorkspace()
        let first = workspace.snapshot()
        let second = workspace.snapshot(reusing: first)
        XCTAssertEqual(first.classes, second.classes)
    }

    func testSnapshotBudgetMarksTruncation() throws {
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        _ = try write("src/main/java/demo/A.java", "class A {}")
        _ = try write("src/main/java/demo/B.java", "class B {}")
        let snapshot = makeWorkspace(maxFiles: 1).snapshot()
        XCTAssertTrue(snapshot.truncated)
        XCTAssertLessThanOrEqual(snapshot.sources.count, 1)
    }

    func testModuleWatchUsesLongestMatchingRoot() throws {
        let submodule = projectRoot.appendingPathComponent("service-a", isDirectory: true)
        let subSource = submodule.appendingPathComponent("src/main/java", isDirectory: true)
        try FileManager.default.createDirectory(at: subSource, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)

        let rootModule = makeModule()
        let subModule = ProjectModule(name: "service-a", directory: submodule)
        let rootTarget = BuildTarget(
            module: rootModule,
            variant: .maven(module: "root", includeProvided: false)
        )
        let subTarget = BuildTarget(
            module: subModule,
            variant: .maven(module: "service-a", includeProvided: false)
        )
        let workspace = HotReloadWorkspace(
            projectRoot: projectRoot,
            primaryModule: rootModule,
            primaryTarget: rootTarget,
            moduleWatches: [
                HotReloadModuleWatch(
                    module: rootModule,
                    target: rootTarget,
                    codeRoots: [sourceRoot],
                    resourceRoots: []
                ),
                HotReloadModuleWatch(
                    module: subModule,
                    target: subTarget,
                    codeRoots: [subSource],
                    resourceRoots: []
                )
            ],
            outputRoots: []
        )

        let subFile = subSource.appendingPathComponent("demo/Sub.java").path
        XCTAssertEqual(workspace.moduleWatch(forSourcePath: subFile)?.module.name, "service-a")
        let rootFile = sourceRoot.appendingPathComponent("demo/Root.java").path
        XCTAssertEqual(workspace.moduleWatch(forSourcePath: rootFile)?.module.name, "demo")
        XCTAssertNil(workspace.moduleWatch(forSourcePath: projectRoot.appendingPathComponent("README.md").path))
    }

    func testSameClassNameInDifferentOutputRootsStaysDistinct() throws {
        let secondRoot = projectRoot.appendingPathComponent("service-b/target/classes", isDirectory: true)
        try FileManager.default.createDirectory(at: classesRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        _ = try write("target/classes/demo/Shared.class", "first-bytes")
        _ = try write("service-b/target/classes/demo/Shared.class", "second-bytes")

        let module = makeModule()
        let target = BuildTarget(module: module, variant: .maven(module: "demo", includeProvided: false))
        let workspace = HotReloadWorkspace(
            projectRoot: projectRoot,
            primaryModule: module,
            primaryTarget: target,
            moduleWatches: [],
            outputRoots: [classesRoot, secondRoot]
        )
        let first = workspace.snapshot()
        let firstPath = classesRoot.appendingPathComponent("demo/Shared.class").path
        let secondPath = secondRoot.appendingPathComponent("demo/Shared.class").path
        XCTAssertEqual(first.classNames[firstPath], "demo.Shared")
        XCTAssertEqual(first.classNames[secondPath], "demo.Shared")
        XCTAssertEqual(
            first.classOrigins[firstPath],
            classesRoot.standardizedFileURL.path
        )
        XCTAssertEqual(
            first.classOrigins[secondPath],
            secondRoot.standardizedFileURL.path
        )

        _ = try write("service-b/target/classes/demo/Shared.class", "second-bytes-longer")
        let single = workspace.snapshot().diff(from: first)
        XCTAssertEqual(single.classChanges.count, 1, "只改一份时不能把另一份也算进来")
        XCTAssertEqual(single.classChanges[0].className, "demo.Shared")
        XCTAssertEqual(
            single.classChanges[0].outputRoot,
            secondRoot.standardizedFileURL.path
        )

        let previous = workspace.snapshot()
        _ = try write("target/classes/demo/Shared.class", "first-bytes-longer")
        _ = try write("service-b/target/classes/demo/Shared.class", "second-bytes-longest")
        let both = workspace.snapshot().diff(from: previous)
        XCTAssertEqual(both.classChanges.count, 2, "同名类必须按输出目录保留两条变更")
        XCTAssertEqual(
            Set(both.classChanges.compactMap(\.outputRoot)),
            [classesRoot.standardizedFileURL.path, secondRoot.standardizedFileURL.path]
        )
        XCTAssertEqual(Set(both.classChanges.map(\.className)), ["demo.Shared"])
    }

    func testRemovedSameNameClassKeepsItsOrigin() throws {
        let secondRoot = projectRoot.appendingPathComponent("service-b/target/classes", isDirectory: true)
        try FileManager.default.createDirectory(at: classesRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        _ = try write("target/classes/demo/Shared.class", "first-bytes")
        _ = try write("service-b/target/classes/demo/Shared.class", "second-bytes")
        let module = makeModule()
        let target = BuildTarget(module: module, variant: .maven(module: "demo", includeProvided: false))
        let workspace = HotReloadWorkspace(
            projectRoot: projectRoot,
            primaryModule: module,
            primaryTarget: target,
            moduleWatches: [],
            outputRoots: [classesRoot, secondRoot]
        )
        let previous = workspace.snapshot()
        try FileManager.default.removeItem(
            at: secondRoot.appendingPathComponent("demo/Shared.class")
        )
        let diff = workspace.snapshot().diff(from: previous)
        XCTAssertEqual(diff.classChanges.count, 1)
        XCTAssertEqual(diff.classChanges[0].kind, .removed)
        XCTAssertEqual(diff.classChanges[0].className, "demo.Shared")
        XCTAssertEqual(
            diff.classChanges[0].outputRoot,
            secondRoot.standardizedFileURL.path
        )
    }

    func testClassNameMappingExcludesMultiReleaseAndModuleInfo() {
        let root = classesRoot.path
        XCTAssertEqual(
            HotReloadWorkspace.className(forClassFile: "\(root)/demo/App$Inner.class", outputRoot: root),
            "demo.App$Inner"
        )
        XCTAssertNil(
            HotReloadWorkspace.className(
                forClassFile: "\(root)/META-INF/versions/9/demo/App.class",
                outputRoot: root
            )
        )
        XCTAssertNil(
            HotReloadWorkspace.className(forClassFile: "\(root)/module-info.class", outputRoot: root)
        )
        XCTAssertNil(
            HotReloadWorkspace.className(
                forClassFile: "/somewhere/else/demo/App.class",
                outputRoot: root
            )
        )
    }
}
