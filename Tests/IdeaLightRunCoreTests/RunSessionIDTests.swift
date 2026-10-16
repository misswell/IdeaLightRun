import XCTest
@testable import IdeaLightRunCore

/// §P0-1: 会话身份 = 项目 + 配置 + 实例。
/// 回归——旧实现用 config.uniqueKey 当会话键，两个项目各有一个同名配置时，
/// 后启动的会话覆盖前一个，前一个的进程从此失联（无法停止、无日志）。
final class RunSessionIDTests: XCTestCase {
    func testInstanceIDsAreUniquePerConstruction() {
        let a = RunSessionID(projectID: "/tmp/A", configurationID: "application::Demo")
        let b = RunSessionID(projectID: "/tmp/A", configurationID: "application::Demo")
        XCTAssertNotEqual(a, b, "同一配置每次 Run 都是新实例，instanceID 必须不同")
        XCTAssertNotEqual(a.instanceID, b.instanceID)
    }

    /// 同名配置分属两个项目：身份必须不同，会话字典不得互相覆盖。
    func testSameConfigurationNameInDifferentProjectsDoNotCollide() {
        let tenant = RunSessionID(projectID: "/work/tenant", configurationID: "application::Demo")
        let gateway = RunSessionID(projectID: "/work/gateway", configurationID: "application::Demo")
        XCTAssertNotEqual(tenant, gateway)
    }

    func testConfigurationScopeKeyFormat() {
        let id = RunSessionID(projectID: "/work/tenant", configurationID: "application::Demo", instanceID: UUID())
        XCTAssertEqual(id.configurationScopeKey, "/work/tenant::application::Demo")
    }

    func testIsCodableRoundTrip() throws {
        let id = RunSessionID(projectID: "/work/tenant", configurationID: "application::Demo")
        let data = try JSONEncoder().encode(id)
        let decoded = try JSONDecoder().decode(RunSessionID.self, from: data)
        XCTAssertEqual(decoded, id)
    }
}
