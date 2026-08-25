import Foundation

/// One `<item>` from a Sparkle appcast.
struct AppcastEntry {
    var version: String?              // sparkle:version — matches CFBundleVersion
    var shortVersion: String?         // sparkle:shortVersionString — matches CFBundleShortVersionString
    var channel: String?              // sparkle:channel — "beta", "nightly", ...
    var minimumSystemVersion: String? // sparkle:minimumSystemVersion
    var link: URL?                    // release notes / product page

    var isStable: Bool {
        guard let channel = channel?.lowercased(), !channel.isEmpty else { return true }
        return channel == "stable" || channel == "release"
    }
}

/// Minimal streaming parser for Sparkle appcast RSS.
final class AppcastParser: NSObject, XMLParserDelegate {

    private var entries: [AppcastEntry] = []
    private var current: AppcastEntry?
    private var textBuffer: String = ""
    private var insideItem = false

    /// A partial parse is still useful — a truncated feed usually contains the
    /// newest `<item>` first — so the return value is the same either way.
    static func parse(_ data: Data) -> [AppcastEntry] {
        let parser = AppcastParser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        xml.shouldProcessNamespaces = false
        xml.parse()
        return parser.entries
    }

    /// The newest stable entry this Mac can actually run.
    static func bestEntry(in entries: [AppcastEntry]) -> AppcastEntry? {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let currentOS = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"

        let usable = entries.filter { entry in
            guard entry.isStable else { return false }
            if let minimum = entry.minimumSystemVersion, !minimum.isEmpty {
                return !Version.isNewer(minimum, than: currentOS)
            }
            return true
        }

        return usable.max { lhs, rhs in
            let left = lhs.version ?? lhs.shortVersion ?? "0"
            let right = rhs.version ?? rhs.shortVersion ?? "0"
            return Version.compare(left, right) == .orderedAscending
        }
    }

    // MARK: - XMLParserDelegate

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {
        textBuffer = ""

        if elementName == "item" {
            insideItem = true
            current = AppcastEntry()
            return
        }
        guard insideItem, elementName == "enclosure" else { return }

        // Sparkle usually puts the versions on the enclosure as attributes.
        if let version = attributeDict["sparkle:version"], current?.version == nil {
            current?.version = version
        }
        if let short = attributeDict["sparkle:shortVersionString"], current?.shortVersion == nil {
            current?.shortVersion = short
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        textBuffer += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        textBuffer += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
        defer { textBuffer = "" }
        let value = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)

        if elementName == "item" {
            if let current { entries.append(current) }
            current = nil
            insideItem = false
            return
        }
        guard insideItem, !value.isEmpty else { return }

        switch elementName {
        case "sparkle:version":
            current?.version = value
        case "sparkle:shortVersionString":
            current?.shortVersion = value
        case "sparkle:channel":
            current?.channel = value
        case "sparkle:minimumSystemVersion":
            current?.minimumSystemVersion = value
        case "link":
            current?.link = URL(string: value)
        default:
            break
        }
    }
}
