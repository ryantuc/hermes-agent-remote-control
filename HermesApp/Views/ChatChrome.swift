import Foundation
import HermesServeKit
import Observation
import SwiftUI

// MARK: - The conversation screen's chrome
//
// The phone deliberately diverges from Hermes Desktop here: the bubbles and the canvas keep the Desktop palette, and the chrome is iOS glass.

/// One entry in the `⋯` overflow. Icon-only, so `accessibilityLabel` is the only text a screen reader has.
enum ChatOverflowAction: String, CaseIterable, Equatable, Identifiable {
    /// The existing read-only `SessionSheetView`.
    case details
    /// The hub's rename alert and `AppModel.renameThread`. Not a new write.
    case rename
    /// The existing `ProjectPickerSheet`, applied through `ChatModel.applyCwd`; a session is in a project because its cwd sits inside that project's path, and there is no `session.project` field to write.
    case project

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .details: return "info.circle"
        case .rename: return "pencil"
        case .project: return "folder"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .details: return "Session details"
        case .rename: return "Rename conversation"
        case .project: return "Move to project"
        }
    }
}

enum ChatChrome {
    /// The overflow's action set, in order: info, pencil, folder. A bot thread is never offered Rename, because a bot conversation's title is the registry key its resolver looks it up by; a draft is not offered it because there is no session id to rename yet.
    static func overflowActions(isBotThread: Bool, isDraft: Bool) -> [ChatOverflowAction] {
        var actions: [ChatOverflowAction] = [.details]
        if !isBotThread && !isDraft { actions.append(.rename) }
        actions.append(.project)
        return actions
    }

    /// The radius the bottom chrome's plate is cut to. Top corners only and full width: a floating full-width surface under a scroll view is what iOS reads as a bottom bar, which reproduces BUG-016.
    static let plateCornerRadius: CGFloat = Radius.sheet

    /// BUG-120: the region the chrome may paint into below the layout bounds. `.container` is the home indicator, and it is neither `.all` nor `.keyboard`, which would re-enter the keyboard's inset negotiation.
    static let homeIndicatorEscape: SafeAreaRegions = .container

    /// BUG-120: height of the layout-neutral fade hanging off the top bar into the transcript. Not a mask on the composer plate, where a fade sits on the well itself and reads as a dirty halo.
    static let frostEdgeFade: CGFloat = Space.s6

    /// What the popover draws: the enabled set, plus the one control that is shown and disabled rather than omitted. A draft's Rename is unavailable only until its first send, so it is greyed; a bot thread's is wrong forever, so it is omitted, and the bot rule wins where both apply.
    static func overflowEntries(isBotThread: Bool, isDraft: Bool) -> [ChatOverflowEntry] {
        let enabled = overflowActions(isBotThread: isBotThread, isDraft: isDraft)
        guard isDraft, !isBotThread else {
            return enabled.map { ChatOverflowEntry(action: $0, isEnabled: true) }
        }
        // Rebuilt in order rather than appended, so the disabled pencil holds the place the enabled one will take.
        // The closure's return type is spelled out because a multi-statement closure gives the compiler nothing to infer `ElementOfResult` from, and the diagnostic names the wrong line.
        return ChatOverflowAction.allCases.compactMap { action -> ChatOverflowEntry? in
            if enabled.contains(action) { return ChatOverflowEntry(action: action, isEnabled: true) }
            guard action == .rename else { return nil }
            return ChatOverflowEntry(action: action, isEnabled: false)
        }
    }
}

/// One drawn row of the `⋯` overflow: an action, and whether it can be taken.
struct ChatOverflowEntry: Equatable, Identifiable {
    let action: ChatOverflowAction
    let isEnabled: Bool

    var id: String { action.id }

    /// What a screen reader hears; a disabled control has to say what it is and why it cannot be used, because `.disabled` alone announces only "dimmed".
    var accessibilityLabel: String {
        isEnabled
            ? action.accessibilityLabel
            : "\(action.accessibilityLabel). Available once this conversation has been sent"
    }
}

// MARK: - Which glass

/// The material the chat chrome is painted in, resolved against the OS the app is running on rather than the SDK it was built with; the deployment target is iOS 17.0 and native Liquid Glass arrived in iOS 26.
enum ChatChromeMaterial: Equatable {
    /// iOS 26 and up, where the navigation bar beside the chat's chrome is the system's own Liquid Glass.
    case liquidGlass
    /// iOS 17 to 25, where no system glass exists anywhere on the screen and the app's frost carries the whole effect.
    case ultraThinMaterial

    /// The first major release with a glass navigation bar.
    static let liquidGlassMinimumMajorVersion = 26

    static func resolve(osMajorVersion: Int) -> ChatChromeMaterial {
        osMajorVersion >= liquidGlassMinimumMajorVersion ? .liquidGlass : .ultraThinMaterial
    }

    /// The frost the chat's own chrome is painted in. Both cases resolve to the same material: `.ultraThinMaterial` is the thinnest SwiftUI defines, and thinning further buys nothing because the transcript stops at the plate's top edge and the plate always sits on flat `canvas`.
    var frost: Material {
        switch self {
        case .liquidGlass: return .ultraThinMaterial
        case .ultraThinMaterial: return .ultraThinMaterial
        }
    }

    static var current: ChatChromeMaterial {
        resolve(osMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    }
}

extension View {
    /// The glass top bar. The background is declared on every OS deliberately: letting the system paint its own bar on iOS 26 also hands the bar its scroll-edge behaviour, which changes the geometry `.defaultScrollAnchor(.bottom)` resolves against and reproduces BUG-016.
    func chatGlassNavigationBar() -> some View {
        toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            // Hit-testing off so the band cannot steal Back, ⋯ or scroll. Do not flip `.toolbarBackground` to `.automatic` (BUG-016).
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .frame(height: ChatChrome.frostEdgeFade)
                    .mask {
                        LinearGradient(
                            colors: [.black, .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }

    /// One frosted plane for the whole bottom stack rather than one per row, so a row appearing does not put a second frost over the first. A material and never `glassEffect`: a full-width `glassEffect` directly beneath a scroll view is read as a bottom bar, which reproduces BUG-016.
    func chatGlassChrome() -> some View {
        background {
            UnevenRoundedRectangle(
                topLeadingRadius: ChatChrome.plateCornerRadius,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: ChatChrome.plateCornerRadius,
                style: .continuous
            )
            .fill(ChatChromeMaterial.current.frost)
            // BUG-120: shaped materials clip to layout bounds, so the plate escapes into the home-indicator well only.
            .ignoresSafeArea(ChatChrome.homeIndicatorEscape, edges: .bottom)
        }
    }
}

// MARK: - The header's second line

/// What the project subtitle says, in `WorkspaceChips`' own vocabulary so Home and Chat never disagree about the same directory. There is no empty case: the unresolved state is an em dash, so the header's height cannot jump when the answer arrives.
enum ChatProjectSubtitle: Equatable {
    /// Nothing has been able to say yet: before the socket opens, or before `projects.for_cwd` answers.
    case unknown
    /// There is no working directory at all.
    case noProject
    /// A directory that belongs to no first-class project: its leaf name.
    case folder(String)
    /// The project `projects.for_cwd` named.
    case project(String)

    var text: String {
        switch self {
        case .unknown: return "—"
        case .noProject: return "No project"
        case .folder(let leaf): return leaf
        case .project(let name): return name
        }
    }

    /// The derivation, given one `projects.for_cwd` answer. `didResolve` is whether the call has come back at all, because claiming "no project" before it has makes every header flicker through the wrong answer.
    static func derive(
        cwd: String,
        projectName: String,
        didResolve: Bool,
        isConnected: Bool
    ) -> ChatProjectSubtitle {
        guard !cwd.isEmpty else {
            return isConnected ? .noProject : .unknown
        }
        if !projectName.isEmpty { return .project(projectName) }
        guard didResolve else { return .unknown }
        return .folder(HostPath.lastComponent(of: cwd))
    }
}

/// Resolves the subtitle for one working directory. It takes the call as a closure rather than a `ProjectsAPI` so the whole derivation, the answer never coming included, is reachable from a test with no socket.
@MainActor
@Observable
final class ChatProjectSubtitleModel {
    typealias ForCwd = (String) async throws -> (project: String?, branch: String)

    private(set) var subtitle: ChatProjectSubtitle = .unknown

    func resolve(cwd: String, isConnected: Bool, forCwd: ForCwd?) async {
        guard isConnected, !cwd.isEmpty, let forCwd else {
            subtitle = ChatProjectSubtitle.derive(
                cwd: cwd,
                projectName: "",
                didResolve: false,
                isConnected: isConnected
            )
            return
        }
        let answer = try? await forCwd(cwd)
        subtitle = ChatProjectSubtitle.derive(
            cwd: cwd,
            projectName: answer?.project ?? "",
            didResolve: answer != nil,
            isConnected: isConnected
        )
    }
}

// MARK: - The overflow itself

/// The three-icon submenu behind `⋯`, as a popover because a SwiftUI `Menu` always renders a labelled list. `presentationCompactAdaptation(.popover)` is what stops iOS turning it into a sheet on a phone.
@MainActor
struct ChatOverflowMenu: View {
    @Environment(\.hermes) private var t

    let entries: [ChatOverflowEntry]
    let onPick: (ChatOverflowAction) -> Void

    var body: some View {
        HStack(spacing: Space.s2) {
            ForEach(entries) { entry in
                Button {
                    onPick(entry.action)
                } label: {
                    Image(systemName: entry.action.systemImage)
                        .font(.system(size: 17, weight: .regular))
                        // A disabled icon needs its own colour: `.disabled` stops the tap but leaves a `.plain` button label painted exactly as it was.
                        .foregroundStyle(entry.isEnabled ? t.text1 : t.text4)
                        .frame(width: Hit.min, height: Hit.min)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!entry.isEnabled)
                .accessibilityLabel(entry.accessibilityLabel)
            }
        }
        .padding(.horizontal, Space.s2)
        .presentationCompactAdaptation(.popover)
    }
}
