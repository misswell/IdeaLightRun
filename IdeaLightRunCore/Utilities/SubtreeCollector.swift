import Foundation

/// 轻量 XML 子树快照。完整文件解析用（.run.xml / runConfigurations / pom / iml 等
/// 小文件）；workspace.xml 走专用流式解析器，只对 RunManager 内的 configuration
/// 建立快照（§101）。
public struct XMLElementNode {
    public var name: String
    public var attributes: [String: String]
    public var children: [XMLElementNode]
    public var text: String?

    public init(name: String, attributes: [String: String] = [:], children: [XMLElementNode] = [], text: String? = nil) {
        self.name = name
        self.attributes = attributes
        self.children = children
        self.text = text
    }

    public func attribute(_ name: String) -> String? { attributes[name] }

    public func firstChild(_ name: String) -> XMLElementNode? {
        children.first { $0.name == name }
    }

    public func childrenNamed(_ name: String) -> [XMLElementNode] {
        children.filter { $0.name == name }
    }
}

/// 按元素名捕获 XML 子树，宽松：解析错误时保留已捕获内容。
final class SubtreeCollector: NSObject, XMLParserDelegate {
    private let shouldCapture: (String) -> Bool
    private(set) var captured: [XMLElementNode] = []

    private var captureActive = false
    private var stack: [XMLElementNode] = []

    init(shouldCapture: @escaping (String) -> Bool) {
        self.shouldCapture = shouldCapture
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if !captureActive && shouldCapture(elementName) {
            captureActive = true
        }
        guard captureActive else { return }
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
        guard captureActive, !stack.isEmpty else { return }
        let finished = stack.removeLast()
        if let parentIndex = stack.indices.last {
            stack[parentIndex].children.append(finished)
        } else {
            captured.append(finished)
            captureActive = false
        }
    }

    private func appendText(_ string: String) {
        guard captureActive, !stack.isEmpty else { return }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let index = stack.count - 1
        stack[index].text = (stack[index].text ?? "") + trimmed
    }
}

/// 便捷入口：解析小 XML 文件并返回匹配名称的所有子树。
enum XMLSubtreeParser {
    static func parse(data: Data, elementName: String) -> [XMLElementNode] {
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        let collector = SubtreeCollector { $0 == elementName }
        parser.delegate = collector
        parser.parse()
        return collector.captured
    }

    static func parse(fileURL: URL, elementName: String) -> [XMLElementNode] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return parse(data: data, elementName: elementName)
    }
}
