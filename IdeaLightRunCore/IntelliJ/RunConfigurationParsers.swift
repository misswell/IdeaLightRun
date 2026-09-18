import Foundation

/// 解析 .run/*.run.xml 与 .idea/runConfigurations/*.xml。
/// 两种文件结构相同：根节点为 component name="ProjectRunConfigurationManager"。
public enum ProjectRunConfigurationParser {
    public static func parse(fileURL: URL, kind: ConfigurationSource.Kind) throws -> [RunConfiguration] {
        let data = try Data(contentsOf: fileURL)
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        let collector = SubtreeCollector { $0 == "configuration" }
        parser.delegate = collector
        // 宽松解析：即使报错也使用已捕获的内容（§10）。
        parser.parse()

        let modifiedAt = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate]) as? Date
        let source = ConfigurationSource(kind: kind, file: fileURL, modifiedAt: modifiedAt)
        return collector.captured.compactMap { RunConfigurationMapper.map(node: $0, source: source) }
    }
}

/// §101: workspace.xml 可能非常大，流式解析，只关注 component name="RunManager"。
public enum WorkspaceRunConfigurationParser {
    public static func parse(fileURL: URL) throws -> [RunConfiguration] {
        let data = try Data(contentsOf: fileURL)
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        let delegate = WorkspaceRunManagerDelegate()
        parser.delegate = delegate
        parser.parse()

        let modifiedAt = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate]) as? Date
        let source = ConfigurationSource(kind: .workspaceXML, file: fileURL, modifiedAt: modifiedAt)
        return delegate.captured.compactMap { RunConfigurationMapper.map(node: $0, source: source) }
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
