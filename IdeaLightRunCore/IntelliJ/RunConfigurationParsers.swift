import Foundation

/// 宽松解析的结果：即使 XML 在中途损坏，已完整捕获的配置仍然可用；
/// `xmlErrorMessage` 让扫描层把"损坏但读到了部分配置"如实告诉用户。
public struct RunConfigurationParseOutcome: Sendable {
    public var configurations: [RunConfiguration]
    public var xmlErrorMessage: String?

    public init(configurations: [RunConfiguration], xmlErrorMessage: String? = nil) {
        self.configurations = configurations
        self.xmlErrorMessage = xmlErrorMessage
    }
}

/// 解析 .run/*.run.xml 与 .idea/runConfigurations/*.xml。
/// 两种文件结构相同：根节点为 component name="ProjectRunConfigurationManager"。
public enum ProjectRunConfigurationParser {
    public static func parse(fileURL: URL, kind: ConfigurationSource.Kind) throws -> [RunConfiguration] {
        try parseOutcome(fileURL: fileURL, kind: kind).configurations
    }

    public static func parseOutcome(fileURL: URL, kind: ConfigurationSource.Kind) throws -> RunConfigurationParseOutcome {
        let data = try Data(contentsOf: fileURL)
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        let collector = SubtreeCollector { $0 == "configuration" }
        parser.delegate = collector
        // 宽松解析：即使报错也使用已捕获的内容（§10）。
        let succeeded = parser.parse()

        let modifiedAt = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate]) as? Date
        let source = ConfigurationSource(kind: kind, file: fileURL, modifiedAt: modifiedAt)
        let configurations = collector.captured.compactMap { RunConfigurationMapper.map(node: $0, source: source) }
        return RunConfigurationParseOutcome(
            configurations: configurations,
            xmlErrorMessage: succeeded ? nil : (parser.parserError?.localizedDescription ?? "XML 解析失败")
        )
    }
}

/// §101: workspace.xml 可能非常大，流式解析，只关注 component name="RunManager"。
public enum WorkspaceRunConfigurationParser {
    public static func parse(fileURL: URL) throws -> [RunConfiguration] {
        try parseOutcome(fileURL: fileURL).configurations
    }

    public static func parseOutcome(fileURL: URL) throws -> RunConfigurationParseOutcome {
        let data = try Data(contentsOf: fileURL)
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        let delegate = WorkspaceRunManagerDelegate()
        parser.delegate = delegate
        let succeeded = parser.parse()

        let modifiedAt = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate]) as? Date
        let source = ConfigurationSource(kind: .workspaceXML, file: fileURL, modifiedAt: modifiedAt)
        let configurations = delegate.captured.compactMap { RunConfigurationMapper.map(node: $0, source: source) }
        return RunConfigurationParseOutcome(
            configurations: configurations,
            xmlErrorMessage: succeeded ? nil : (parser.parserError?.localizedDescription ?? "XML 解析失败")
        )
    }
}

final class WorkspaceRunManagerDelegate: NSObject, XMLParserDelegate {
    private(set) var captured: [XMLElementNode] = []

    private var insideRunManager = false
    private var stack: [XMLElementNode] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "component" {
            insideRunManager = (attributeDict["name"] == "RunManager")
            // component 自身不参与子树构建，只作为开关。
            return
        }
        guard insideRunManager else { return }
        stack.append(XMLElementNode(name: elementName, attributes: attributeDict))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        appendText(string)
    }

    func parser(_ parser: XMLParser, foundCDATA CDATADevice: Data) {
        if let string = String(data: CDATADevice, encoding: .utf8) {
            appendText(string)
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "component" {
            insideRunManager = false
            return
        }
        guard insideRunManager, !stack.isEmpty else { return }
        let finished = stack.removeLast()
        if let parentIndex = stack.indices.last {
            stack[parentIndex].children.append(finished)
        } else if finished.name == "configuration" {
            captured.append(finished)
        }
    }

    private func appendText(_ string: String) {
        guard insideRunManager, !stack.isEmpty else { return }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let index = stack.count - 1
        stack[index].text = (stack[index].text ?? "") + trimmed
    }
}
