import Foundation

public enum IntelliJSDKReader {
    public struct ProjectSDK: Equatable, Codable, Sendable {
        public var name: String
        public var type: String?

        public init(name: String, type: String?) {
            self.name = name
            self.type = type
        }
    }

    /// §23: 读取 .idea/misc.xml 的 project-jdk-name。
    public static func readProjectSDK(projectRoot: URL) -> ProjectSDK? {
        let miscFile = projectRoot.appendingPathComponent(".idea/misc.xml")
        let components = XMLSubtreeParser.parse(fileURL: miscFile, elementName: "component")
        guard let component = components.first(where: { $0.attribute("name") == "ProjectRootManager" }),
              let name = component.attribute("project-jdk-name"),
              !name.isEmpty else {
            return nil
        }
        return ProjectSDK(name: name, type: component.attribute("project-jdk-type"))
    }
}
