import Foundation

public struct SlashCompletionItem: Sendable, Equatable, Identifiable {
    public var id: String { text }
    public let text: String
    public let display: String
    public let meta: String
    public let kind: String?

    public init(text: String, display: String? = nil, meta: String = "", kind: String? = nil) {
        self.text = text
        self.display = display ?? text
        self.meta = meta
        self.kind = kind
    }

    public init?(json: JSONValue) {
        guard let text = json["text"]?.stringValue, !text.isEmpty else { return nil }
        self.init(text: text, display: json["display"]?.stringValue,
                  meta: json["meta"]?.stringValue ?? "", kind: json["kind"]?.stringValue)
    }
}

public struct SlashCompletionResult: Sendable, Equatable {
    public let items: [SlashCompletionItem]
    /// Python character (Unicode scalar) offset, not a UIKit UTF-16 offset.
    public let replaceFrom: Int?

    public init(items: [SlashCompletionItem], replaceFrom: Int? = nil) {
        self.items = items
        self.replaceFrom = replaceFrom
    }

    public init(json: JSONValue) {
        items = (json["items"]?.arrayValue ?? json.arrayValue ?? []).compactMap(SlashCompletionItem.init(json:))
        replaceFrom = json["replace_from"]?.coercedInt
    }
}

public struct SlashCatalogEntry: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let description: String
    public let category: String?
    public let kind: String?
    public let canonicalName: String?
    public let desktopAction: String?

    public init(name: String, description: String = "", category: String? = nil,
                kind: String? = nil, canonicalName: String? = nil, desktopAction: String? = nil) {
        self.name = SlashCommandSupport.normalizedName(name)
        self.description = description
        self.category = category
        self.kind = kind
        self.canonicalName = canonicalName
        self.desktopAction = desktopAction
    }
}

/// Optional catalog sections enrich discovery; a warning does not invalidate usable rows.
public struct SlashCommandCatalog: Sendable, Equatable {
    public let entries: [SlashCatalogEntry]
    public let warning: String?
    public let aliases: [String: String]

    public init(entries: [SlashCatalogEntry] = [], warning: String? = nil, aliases: [String: String] = [:]) {
        self.entries = entries
        self.warning = warning
        self.aliases = aliases
    }

    public init(json: JSONValue) {
        let categories = json["categories"]?.arrayValue ?? []
        var categoryFor: [String: String] = [:]
        var pairs = json["pairs"]?.arrayValue ?? []
        for category in categories {
            for pair in category["pairs"]?.arrayValue ?? [] {
                guard let name = pair[0]?.stringValue else { continue }
                categoryFor[SlashCommandSupport.normalizedName(name)] = category["name"]?.stringValue
                pairs.append(pair)
            }
        }
        let decodedAliases: [String: String] = (json["canon"]?.objectValue ?? [:]).reduce(into: [:]) { result, row in
            if let value = row.value.stringValue {
                result[SlashCommandSupport.normalizedName(row.key)] = SlashCommandSupport.normalizedName(value)
            }
        }
        aliases = decodedAliases
        let skills = json["skills"]?.objectValue ?? [:]
        let metadata = json["commands"]?.objectValue ?? [:]
        var seen = Set<String>()
        entries = pairs.compactMap { pair in
            guard let rawName = pair[0]?.stringValue, !rawName.isEmpty else { return nil }
            let name = SlashCommandSupport.normalizedName(rawName)
            guard seen.insert(name).inserted else { return nil }
            let category = categoryFor[name]
            let kind = skills[name] != nil ? "skill"
                : category == "User commands" ? "quick"
                : category == "Plugin commands" ? "plugin" : nil
            return SlashCatalogEntry(name: name, description: pair[1]?.stringValue ?? "",
                                     category: category, kind: kind, canonicalName: decodedAliases[name],
                                     desktopAction: metadata[name]?["desktop"]?.stringValue)
        }
        let notice = json["warning"]?.stringValue ?? ""
        warning = notice.isEmpty ? nil : notice
    }

    public func entry(named name: String) -> SlashCatalogEntry? {
        let key = SlashCommandSupport.normalizedName(name)
        let canonical = aliases[key] ?? key
        return entries.first { $0.name == key } ?? entries.first { $0.name == canonical }
    }
}

/// Shared by discovery and dispatch so Desktop-only actions never appear functional on HARC.
public enum SlashCommandSupport {
    /// `/btw` runs here through `prompt.btw`, never the slash worker, as Desktop's own handler does (`apps/desktop/src/app/session/hooks/use-prompt-actions/slash.ts:555-600`).
    public static let localCommands: Set<String> = ["/help", "/commands", "/stop", "/status", "/save", "/btw"]
    /// Commands the composer answers in HARC's own interface before anything is sent, with the line the suggestion list shows for each. The list offers them whatever the backend advertises; dispatch still refuses them, so one that reaches the send path is never sent.
    public static let interfaceCommands: [String: String] = ["/model": "Open the model picker"]
    private static let unavailable: Set<String> = [
        "/new", "/reset", "/branch", "/fork", "/yolo", "/reasoning", "/wake", "/handoff",
        "/profile", "/skin", "/title", "/browser", "/journey", "/learning", "/memory-graph",
        "/model", "/resume", "/sessions", "/switch", "/compress", "/compact",
        "/pet", "/pets", "/hatch", "/generate-pet", "/density", "/details", "/logs", "/mouse",
        // Registry Desktop actions, including aliases, when older discovery omits `commands` metadata.
        "/clear", "/redraw", "/history", "/snapshot", "/snap", "/approve", "/deny",
        "/sethome", "/set-home", "/config", "/statusbar", "/sb", "/verbose", "/footer",
        "/fast", "/indicator", "/voice", "/busy", "/toolsets", "/skills", "/cron",
        "/curator", "/kanban", "/reload", "/reload-mcp", "/reload_mcp", "/reload-skills",
        "/reload_skills", "/plugins", "/restart", "/login", "/insights", "/platforms",
        "/gateway", "/copy", "/paste", "/image", "/update", "/quit", "/exit",
        // These open terminal-local UI or an editor and have no phone equivalent.
        "/prompt", "/compose", "/palette", "/battery", "/timestamps", "/ts", "/focus",
    ]

    public static func normalizedName(_ name: String) -> String {
        "/" + name.trimmingCharacters(in: .whitespacesAndNewlines).drop(while: { $0 == "/" }).lowercased()
    }

    public static func supports(name: String, desktopAction: String? = nil) -> Bool {
        let name = normalizedName(name)
        if desktopAction == "hidden" { return false }
        if localCommands.contains(name) { return true }
        if unavailable.contains(name) { return false }
        return desktopAction?.isEmpty != false
    }

    public static func supports(_ entry: SlashCatalogEntry) -> Bool {
        supports(name: entry.canonicalName ?? entry.name, desktopAction: entry.desktopAction)
    }

    public static func unavailableReason(name: String, entry: SlashCatalogEntry?) -> String? {
        let supported = entry.map { supports($0) } ?? supports(name: name)
        return supported ? nil : "\(normalizedName(name)) is not available in HARC. The draft has been kept."
    }
}

public struct SlashDispatchResult: Sendable, Equatable {
    public let type: String?
    public let output: String?
    public let message: String?
    public let display: String?
    public let notice: String?
    public let target: String?
    public let name: String?
    public let warning: String?
    public let raw: JSONValue

    public init(json: JSONValue) {
        type = json["type"]?.stringValue
        output = json["output"]?.stringValue
        message = json["message"]?.stringValue
        display = json["display"]?.stringValue
        notice = json["notice"]?.stringValue
        target = json["target"]?.stringValue
        name = json["name"]?.stringValue
        warning = json["warning"]?.stringValue
        raw = json
    }
}

public protocol SlashCommandDiscovering: Sendable {
    func complete(text: String, sessionID: String?, profile: String?) async throws -> SlashCompletionResult
    func catalog(sessionID: String?, profile: String?) async throws -> SlashCommandCatalog
}

/// Successful responses establish discovery capability; these RPCs need no shared-session extension.
///
/// The backend's params models forbid undeclared keys and answer 4000 before the handler runs. `complete.slash` declares `text`, `session_id` and `profile`; `commands.catalog` declares `session_id` and `profile`. Neither declares `cwd`: a bound session already carries its workspace, so the scope is the session, or for a session-less draft its Hermes profile, exactly as Desktop sends it.
public struct SlashCommandsAPI: SlashCommandDiscovering {
    private let client: HermesClient
    public init(client: HermesClient) { self.client = client }

    public func complete(text: String, sessionID: String? = nil, profile: String? = nil) async throws -> SlashCompletionResult {
        var params = Self.scopeParams(sessionID: sessionID, profile: profile)
        params["text"] = .string(text)
        return SlashCompletionResult(json: try await client.request("complete.slash", params: .object(params), timeout: 5))
    }

    public func catalog(sessionID: String? = nil, profile: String? = nil) async throws -> SlashCommandCatalog {
        SlashCommandCatalog(json: try await client.request("commands.catalog", params: .object(Self.scopeParams(sessionID: sessionID, profile: profile)), timeout: 5))
    }

    public func execute(sessionID: String, line: String) async throws -> SlashDispatchResult {
        SlashDispatchResult(json: try await client.request("slash.exec", params: .object([
            "session_id": .string(sessionID), "command": .string(line),
        ])))
    }

    public func dispatch(sessionID: String, name: String, argument: String = "") async throws -> SlashDispatchResult {
        SlashDispatchResult(json: try await client.request("command.dispatch", params: .object([
            "session_id": .string(sessionID), "name": .string(String(name.drop(while: { $0 == "/" }))),
            "arg": .string(argument),
        ])))
    }

    /// A bound session wins: the backend resolves its profile home and workspace from the session record, and `profile` only scopes a session-less request.
    private static func scopeParams(sessionID: String?, profile: String?) -> [String: JSONValue] {
        if let sessionID, !sessionID.isEmpty { return ["session_id": .string(sessionID)] }
        if let profile, !profile.isEmpty { return ["profile": .string(profile)] }
        return [:]
    }
}

public struct SlashCompletionEdit: Sendable, Equatable {
    public let sourceText: String
    public let sourceSelection: NSRange
    public let range: NSRange
    public let insertion: String
    public let text: String
    public let selection: NSRange
}

/// Pure range logic: the server sees only text up to the caret; a completion replaces that token,
/// including an existing token tail, while keeping arguments, newlines, and the rest of the draft.
public enum SlashCompletionText {
    public static func commandName(in text: String) -> String? {
        guard text.hasPrefix("/") else { return nil }
        let token = String(text.dropFirst().prefix { !$0.isWhitespace })
        guard token.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }) else { return nil }
        return "/" + token.lowercased()
    }

    public static func query(text: String, selection: NSRange, isComposing: Bool = false) -> String? {
        guard !isComposing, selection.length == 0, selection.location > 0,
              isScalarBoundary(selection.location, in: text as NSString),
              let prefixRange = Range(NSRange(location: 0, length: selection.location), in: text),
              commandName(in: text) != nil else { return nil }
        let prefix = String(text[prefixRange])
        guard !prefix.contains("\n"), !prefix.contains("\r"), !prefix.contains("\t") else { return nil }
        return prefix
    }

    public static func applying(_ item: SlashCompletionItem, replaceFrom: Int?, text: String, selection: NSRange) -> SlashCompletionEdit? {
        guard let query = query(text: text, selection: selection) else { return nil }
        let commandStage = !query.contains(" ")
        guard let scalarOffset = replaceFrom ?? (commandStage ? 1 : nil), scalarOffset >= 0,
              scalarOffset <= query.unicodeScalars.count else { return nil }
        let scalarIndex = query.unicodeScalars.index(query.unicodeScalars.startIndex, offsetBy: scalarOffset)
        let start = String(query.unicodeScalars[..<scalarIndex]).utf16.count
        guard start <= selection.location else { return nil }
        let utf16 = text as NSString
        var end = selection.location
        while end < utf16.length {
            let character = utf16.character(at: end)
            if let scalar = UnicodeScalar(character), CharacterSet.whitespacesAndNewlines.contains(scalar) { break }
            end += 1
        }
        let range = NSRange(location: start, length: end - start)
        guard isScalarBoundary(start, in: utf16), isScalarBoundary(end, in: utf16),
              Range(range, in: text) != nil else { return nil }
        var insertion = item.text
        if start > 0, utf16.substring(with: NSRange(location: start - 1, length: 1)) == "/", insertion.hasPrefix("/") {
            insertion.removeFirst()
        }
        // Command names get one separator to enter argument completion. Argument rows retain the
        // server's insertion verbatim, except a returned separator must not duplicate the draft's.
        if end < utf16.length,
           let next = UnicodeScalar(utf16.character(at: end)), CharacterSet.whitespacesAndNewlines.contains(next) {
            while insertion.last?.isWhitespace == true { insertion.removeLast() }
        } else if commandStage, end == utf16.length, insertion.last?.isWhitespace != true {
            insertion += " "
        }
        let result = utf16.replacingCharacters(in: range, with: insertion)
        return SlashCompletionEdit(sourceText: text, sourceSelection: selection, range: range, insertion: insertion,
                                   text: result, selection: NSRange(location: start + insertion.utf16.count, length: 0))
    }

    /// Foundation accepts some NSRanges splitting surrogate pairs; validate before bridging/slicing.
    private static func isScalarBoundary(_ offset: Int, in text: NSString) -> Bool {
        guard offset >= 0, offset <= text.length else { return false }
        guard offset > 0, offset < text.length else { return true }
        let previous = text.character(at: offset - 1)
        let next = text.character(at: offset)
        return !((0xD800...0xDBFF).contains(previous) && (0xDC00...0xDFFF).contains(next))
    }
}
