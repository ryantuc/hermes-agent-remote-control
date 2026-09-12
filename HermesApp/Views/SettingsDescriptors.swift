import Foundation
import HermesServeKit

/// The settings tree's content: which screens exist, which rows they carry, and how each row edits, with labels and option sets following the desktop's `constants.ts`.
/// Where the live schema serves options (`/api/config/schema`) the schema wins; static lists are the fallback for fields the schema types as plain strings.

struct SettingOption: Identifiable, Equatable {
    let value: String
    let label: String
    var id: String { value }

    init(_ value: String, _ label: String? = nil) {
        self.value = value
        self.label = label ?? (value.isEmpty ? "Default" : value)
    }
}

enum SettingRowKind {
    /// Boolean → `SwitchRow`.
    case toggle
    /// 2–3 closed options → `SegmentedRow`; a value in `holdFor` is destructive and arms an inline `HoldToConfirmButton` instead of committing on the tap.
    case segment([SettingOption], holdFor: Set<String> = [])
    /// A larger closed set → pushed option sheet; pass nil to use the schema's options for the key.
    case options([SettingOption]?)
    /// Free string → editor sheet.
    case text(placeholder: String)
    /// Number → editor sheet. `integer` drives keyboard and formatting.
    case number(integer: Bool)
    /// `[String]` value → list editor sheet.
    case stringList(addPrompt: String)
    /// Read-only display — a value the phone shows but does not edit.
    case display
}

struct SettingRowDescriptor: Identifiable {
    /// Dotted path into the config document.
    let key: String
    let label: String
    var description: String?
    var advanced = false
    /// What this row reads when the backend reports the key as absent or `null`, and the row's licence to stay on screen at all, since a key the gateway does not report otherwise removes its row (BUG-042).
    var unsetLabel: String?
    let kind: SettingRowKind
    var id: String { key }

    init(
        _ key: String,
        _ label: String,
        description: String? = nil,
        advanced: Bool = false,
        unsetLabel: String? = nil,
        kind: SettingRowKind
    ) {
        self.key = key
        self.label = label
        self.description = description
        self.advanced = advanced
        self.unsetLabel = unsetLabel
        self.kind = kind
    }
}

extension SettingRowDescriptor {
    /// The trailing text of a `.number` row, given whatever the document holds for its key, including nothing at all.
    /// BUG-042: a JSON `null` fails `coercedDouble` and an empty trailing value reads as "unset or broken" rather than "no cap", so an `unsetLabel` names that state and covers every spelling the backend folds into "no limit".
    func numberDisplay(_ value: JSONValue?, integer: Bool) -> String {
        guard let value, !value.isNull else { return unsetLabel ?? "" }
        if unsetLabel != nil, Self.readsAsUnlimited(value) { return unsetLabel ?? "" }
        guard let number = value.coercedDouble else {
            return unsetLabel ?? (value.coercedString ?? "")
        }
        if integer || number.rounded() == number { return Self.integerText(number) }
        return String(number)
    }

    /// The largest magnitude that can go through `Int(_: Double)`, which traps for a finite value outside `Int64`'s range (BUG-109).
    /// The round number below `Int64.max` is the honest cap because the nearest `Double` to `Int64.max` is above it, so comparing against the exact maximum is itself a trap.
    static let integerConversionCap = 9.2e18

    /// The most characters a numeric editor field will hold, since `.numberPad` has no length limit of its own.
    /// Twenty-four leaves room to type an out-of-range number, which the user must be able to do or the inline "Too large" can never appear.
    static let numericDraftMaxLength = 24

    /// A whole number as text, without the trapping conversion.
    static func integerText(_ number: Double) -> String {
        guard number.isFinite, abs(number) < integerConversionCap else {
            return number.formatted(.number.notation(.scientific))
        }
        return String(Int(number))
    }

    /// The editor sheet's seed text for a stored number.
    static func draftText(for number: Double) -> String {
        guard number.isFinite, abs(number) < integerConversionCap else {
            return number.formatted(.number.notation(.scientific))
        }
        return number.rounded() == number ? String(Int(number)) : String(number)
    }

    /// Mirrors `hermes_cli.config.resolve_turn_limit`'s accepted spellings of "no limit", excluding bools as it does, since a `bool` is an `int` in Python.
    static func readsAsUnlimited(_ value: JSONValue) -> Bool {
        switch value {
        case .null:
            return true
        case .bool:
            return false
        case .number(let n):
            return n <= 0
        case .string(let s):
            let trimmed = s.trimmingCharacters(in: .whitespaces).lowercased()
            if trimmed.isEmpty { return true }
            if unlimitedSpellings.contains(trimmed) { return true }
            if let n = Double(trimmed) { return n <= 0 }
            return false
        case .array, .object:
            return false
        }
    }

    private static let unlimitedSpellings: Set<String> = [
        "none", "null", "unlimited", "infinite", "infinity", "inf", "∞",
    ]

    /// What the editor sheet's Save button writes for `draft`, or nil when there is nothing to write and the tap should do nothing.
    /// BUG-042: a row that names its unset state is returned to it by writing `0`, which the backend takes as a first-class spelling of no limit, where a JSON `null` would be at the mercy of how `PUT /api/config` deep-merges one.
    func editedValue(_ draft: String, numeric: Bool) -> JSONValue? {
        guard case .value(let value) = editOutcome(draft, numeric: numeric) else { return nil }
        return value
    }

    /// What Save should do with `draft`, and when the answer is "nothing", why, in words the sheet can put under the field (BUG-096).
    /// BUG-109: `.tooLarge` is what stops the poison value ever reaching the backend.
    enum EditOutcome: Equatable {
        case value(JSONValue)
        /// The field is empty and this row has no name for "unset".
        case empty
        case notANumber
        /// Beyond what `Int64`, and therefore this app's rendering of a whole number, can carry.
        case tooLarge

        /// The sentence that goes under the field, empty for a value.
        var message: String {
            switch self {
            case .value: return ""
            case .empty: return "Enter a value."
            case .notANumber: return "Enter a number."
            case .tooLarge: return "Too large."
            }
        }
    }

    func editOutcome(_ draft: String, numeric: Bool) -> EditOutcome {
        guard numeric else {
            return .value(.string(draft.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return unsetLabel == nil ? .empty : .value(.number(0))
        }
        guard let number = Double(trimmed) else { return .notANumber }
        guard number.isFinite, abs(number) < Self.integerConversionCap else { return .tooLarge }
        return .value(.number(number))
    }
}

struct SettingsSectionDescriptor: Identifiable {
    let header: String?
    let rows: [SettingRowDescriptor]
    var id: String { header ?? rows.first?.key ?? "" }
}

enum SettingsScreenID: String, Hashable, CaseIterable {
    case modelReasoning
    case personality
    case transcript
    case workspace
    case safety
    case memory
    case advanced
    case about
    // Workspace pages — hand-built views, not descriptor-driven.
    case capabilities
    case artifacts
    case messaging
    /// The `+` sheet's quick-action membership and order.
    case composerActions
    /// Dictation engine and voice chat: device choices, plus the backend's `stt`/`tts` providers read-only.
    case voice
    /// Live Activities and what notifies; client-local and bespoke.
    case notifications
    /// FEAT-031's grouping screen for the four device-side chat choices, hand-built because none of its values is in the backend's config document.
    case chat
}

struct SettingsScreenDescriptor {
    let id: SettingsScreenID
    let title: String
    let sections: [SettingsSectionDescriptor]
}

enum SettingsCatalog {
    /// The shared effort scale, matching the desktop's `REASONING_EFFORTS`.
    static let effortScale = ["minimal", "low", "medium", "high", "xhigh", "max", "ultra"]

    /// The options the Default effort row offers, which is the scale plus none, first in the list because it is the bottom of the ladder.
    /// BUG-097: `agent.reasoning_effort` accepts `none` on the backend but `/api/config/schema` types the key as a plain string, so without it here reasoning turned off elsewhere could never be selected again.
    static let effortOptions: [SettingOption] =
        [SettingOption("none", "None")] + effortScale.map { SettingOption($0) }

    /// `BUILTIN_PERSONALITIES`, desktop order, plus the backend's "none".
    static let personalities = [
        "none", "helpful", "concise", "technical", "creative", "teacher",
        "kawaii", "catgirl", "pirate", "shakespeare", "surfer", "noir",
        "uwu", "philosopher", "hype",
    ]

    static func screen(_ id: SettingsScreenID) -> SettingsScreenDescriptor {
        switch id {
        case .modelReasoning: return modelReasoning
        case .personality: return personality
        case .workspace: return workspace
        case .safety: return safety
        case .memory: return memory
        case .advanced: return advanced
        // Hand-built screens, not descriptor-driven.
        case .transcript, .about, .capabilities, .artifacts, .messaging, .composerActions, .voice,
             .notifications, .chat:
            return SettingsScreenDescriptor(id: id, title: "", sections: [])
        }
    }

    // MARK: Chat

    static let modelReasoning = SettingsScreenDescriptor(
        id: .modelReasoning,
        title: "Model & reasoning",
        sections: [
            SettingsSectionDescriptor(header: "Model", rows: [
                SettingRowDescriptor(
                    "model", "Default model",
                    description: "provider/model slug, as the CLI accepts it. New conversations start here; the composer pill changes one conversation.",
                    kind: .text(placeholder: "provider/model")
                ),
                SettingRowDescriptor(
                    "fallback_providers", "Fallback models",
                    description: "Provider + model pairs tried when the primary fails. Edited from the desktop or CLI.",
                    kind: .display
                ),
                SettingRowDescriptor(
                    "model_context_length", "Context window",
                    description: "Tokens. 0 auto-detects from the catalogue.",
                    advanced: true,
                    kind: .number(integer: true)
                ),
            ]),
            SettingsSectionDescriptor(header: "Reasoning", rows: [
                SettingRowDescriptor(
                    "agent.reasoning_effort", "Default effort",
                    kind: .options(SettingsCatalog.effortOptions)
                ),
                SettingRowDescriptor(
                    "display.show_reasoning", "Show reasoning",
                    kind: .toggle
                ),
                SettingRowDescriptor(
                    "delegation.reasoning_effort", "Subagent effort",
                    description: "Blank inherits the agent's own effort.",
                    advanced: true,
                    kind: .options(nil)
                ),
            ]),
        ]
    )

    static let personality = SettingsScreenDescriptor(
        id: .personality,
        title: "Personality",
        sections: [
            SettingsSectionDescriptor(header: nil, rows: [
                SettingRowDescriptor(
                    "display.personality", "Personality",
                    kind: .options(SettingsCatalog.personalities.map {
                        SettingOption($0, $0 == "none" ? "None" : $0.capitalized)
                    })
                ),
                SettingRowDescriptor(
                    "timezone", "Timezone",
                    description: "IANA name, e.g. America/Chicago. Blank follows the backend host.",
                    kind: .text(placeholder: "America/Chicago")
                ),
            ]),
        ]
    )

    // MARK: Agent

    static let workspace = SettingsScreenDescriptor(
        id: .workspace,
        title: "Workspace",
        sections: [
            SettingsSectionDescriptor(header: "Working directory", rows: [
                SettingRowDescriptor(
                    "terminal.cwd", "Working directory",
                    description: "Where new conversations start. The folder picker lands with the platform phase; the path is editable here meanwhile.",
                    kind: .text(placeholder: "~")
                ),
            ]),
            SettingsSectionDescriptor(header: "Repositories", rows: [
                SettingRowDescriptor(
                    "desktop.repo_scan_enabled", "Discover repositories",
                    kind: .toggle
                ),
                SettingRowDescriptor(
                    "desktop.repo_scan_roots", "Discovery roots",
                    kind: .stringList(addPrompt: "Add a root path")
                ),
                SettingRowDescriptor(
                    "desktop.repo_scan_exclude_paths", "Excluded paths",
                    advanced: true,
                    kind: .stringList(addPrompt: "Add an excluded path")
                ),
            ]),
            SettingsSectionDescriptor(header: "Execution", rows: [
                SettingRowDescriptor(
                    "code_execution.mode", "Code execution",
                    description: "Strict confines execution to the working directory.",
                    kind: .segment([SettingOption("project"), SettingOption("strict")])
                ),
                SettingRowDescriptor(
                    "terminal.persistent_shell", "Persistent shell",
                    kind: .toggle
                ),
                SettingRowDescriptor(
                    "terminal.env_passthrough", "Environment passthrough",
                    description: "Variable names forwarded into tool shells.",
                    advanced: true,
                    kind: .stringList(addPrompt: "Add a variable name")
                ),
                SettingRowDescriptor(
                    "file_read_max_chars", "File read limit",
                    description: "Characters per read before truncation.",
                    advanced: true,
                    kind: .number(integer: true)
                ),
            ]),
        ]
    )

    static let safety = SettingsScreenDescriptor(
        id: .safety,
        title: "Safety & approvals",
        sections: [
            SettingsSectionDescriptor(header: "Approvals", rows: [
                SettingRowDescriptor(
                    "approvals.mode", "Approval mode",
                    description: "Off runs every command without asking. Smart asks for the risky ones.",
                    kind: .segment(
                        [SettingOption("manual"), SettingOption("smart"), SettingOption("off")],
                        holdFor: ["off"]
                    )
                ),
                SettingRowDescriptor(
                    "approvals.timeout", "Approval timeout",
                    description: "Seconds before an unanswered approval fails closed.",
                    kind: .number(integer: true)
                ),
                SettingRowDescriptor(
                    "approvals.mcp_reload_confirm", "Confirm MCP reloads",
                    advanced: true,
                    kind: .toggle
                ),
                SettingRowDescriptor(
                    "command_allowlist", "Command allowlist",
                    description: "Commands that skip the approval ladder entirely.",
                    kind: .stringList(addPrompt: "Add a command")
                ),
            ]),
            SettingsSectionDescriptor(header: "Security", rows: [
                SettingRowDescriptor(
                    "security.redact_secrets", "Redact secrets",
                    kind: .toggle
                ),
                SettingRowDescriptor(
                    "security.allow_private_urls", "Allow private URLs",
                    description: "Lets tools fetch RFC-1918 and localhost addresses.",
                    advanced: true,
                    kind: .toggle
                ),
                SettingRowDescriptor(
                    "browser.allow_private_urls", "Browser private URLs",
                    advanced: true,
                    kind: .toggle
                ),
                SettingRowDescriptor(
                    "browser.auto_local_for_private_urls", "Local browser for private URLs",
                    advanced: true,
                    kind: .toggle
                ),
            ]),
            SettingsSectionDescriptor(header: "Checkpoints", rows: [
                SettingRowDescriptor(
                    "checkpoints.enabled", "Checkpoints",
                    description: "Snapshot edited files so a bad turn can be rolled back.",
                    kind: .toggle
                ),
            ]),
        ]
    )

    static let memory = SettingsScreenDescriptor(
        id: .memory,
        title: "Memory & context",
        sections: [
            SettingsSectionDescriptor(header: "Memory", rows: [
                SettingRowDescriptor("memory.memory_enabled", "Memory", kind: .toggle),
                SettingRowDescriptor("memory.user_profile_enabled", "User profile", kind: .toggle),
                SettingRowDescriptor(
                    "memory.memory_char_limit", "Memory budget",
                    description: "Characters of recalled memory per prompt.",
                    advanced: true,
                    kind: .number(integer: true)
                ),
                SettingRowDescriptor(
                    "memory.user_char_limit", "Profile budget",
                    advanced: true,
                    kind: .number(integer: true)
                ),
                SettingRowDescriptor(
                    "memory.provider", "Memory provider",
                    description: "Discovered providers come from the backend.",
                    kind: .options(nil)
                ),
            ]),
            SettingsSectionDescriptor(header: "Context", rows: [
                SettingRowDescriptor(
                    "context.engine", "Context engine",
                    kind: .options(nil)
                ),
                SettingRowDescriptor("compression.enabled", "Compression", kind: .toggle),
                SettingRowDescriptor(
                    "compression.threshold", "Compression threshold",
                    description: "Fraction of the context window that triggers compression.",
                    advanced: true,
                    kind: .number(integer: false)
                ),
                SettingRowDescriptor(
                    "compression.target_ratio", "Compression target",
                    advanced: true,
                    kind: .number(integer: false)
                ),
                SettingRowDescriptor(
                    "compression.protect_last_n", "Protected messages",
                    description: "Recent messages compression never touches.",
                    advanced: true,
                    kind: .number(integer: true)
                ),
            ]),
        ]
    )

    static let advanced = SettingsScreenDescriptor(
        id: .advanced,
        title: "Advanced",
        sections: [
            SettingsSectionDescriptor(header: "Tools", rows: [
                SettingRowDescriptor(
                    "toolsets", "Toolsets",
                    description: "Which tool families the agent may load.",
                    kind: .stringList(addPrompt: "Add a toolset")
                ),
                SettingRowDescriptor(
                    "agent.image_input_mode", "Image input",
                    kind: .options([SettingOption("auto"), SettingOption("native"), SettingOption("text")])
                ),
            ]),
            SettingsSectionDescriptor(header: "Terminal", rows: [
                SettingRowDescriptor("terminal.backend", "Terminal backend", kind: .options(nil)),
                SettingRowDescriptor(
                    "terminal.timeout", "Command timeout",
                    description: "Seconds before a tool command is cut off.",
                    kind: .number(integer: true)
                ),
            ]),
            SettingsSectionDescriptor(header: "Tool output", rows: [
                SettingRowDescriptor("tool_output.max_bytes", "Output cap (bytes)", kind: .number(integer: true)),
                SettingRowDescriptor("tool_output.max_lines", "Output cap (lines)", kind: .number(integer: true)),
                SettingRowDescriptor("tool_output.max_line_length", "Line length cap", kind: .number(integer: true)),
            ]),
            SettingsSectionDescriptor(header: "Agent", rows: [
                SettingRowDescriptor(
                    "agent.max_turns",
                    "Max steps per turn",
                    description: "No cap unless you set one. Save an empty field to put it back to unlimited.",
                    unsetLabel: "Unlimited",
                    kind: .number(integer: true)
                ),
                SettingRowDescriptor("agent.api_max_retries", "API retries", kind: .number(integer: true)),
                SettingRowDescriptor("checkpoints.max_snapshots", "Checkpoint snapshots", kind: .number(integer: true)),
            ]),
            SettingsSectionDescriptor(header: "Subagents", rows: [
                SettingRowDescriptor(
                    "delegation.model", "Subagent model",
                    description: "Blank inherits the agent's model.",
                    kind: .text(placeholder: "provider/model")
                ),
                SettingRowDescriptor("delegation.max_concurrent_children", "Concurrent subagents", kind: .number(integer: true)),
                SettingRowDescriptor("delegation.max_iterations", "Subagent iterations", kind: .number(integer: true)),
                SettingRowDescriptor("delegation.child_timeout_seconds", "Subagent timeout", kind: .number(integer: true)),
            ]),
        ]
    )
}
