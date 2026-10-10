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
    /// `PromptTimelineSheet`: the conversation's prompts, each a jump.
    case timeline

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .details: return "info.circle"
        case .rename: return "pencil"
        case .project: return "folder"
        case .timeline: return "list.bullet.below.rectangle"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .details: return "Session details"
        case .rename: return "Rename conversation"
        case .project: return "Move to project"
        case .timeline: return "Jump to a prompt"
        }
    }
}

enum ChatChrome {
    /// Off until a jump survives leaving and reopening the chat: a windowed page reopened after a successful replay reads as the end of the conversation.
    static let promptTimelineEnabled = false

    /// The overflow's action set, in order: info, pencil, folder. A bot thread is never offered Rename, because a bot conversation's title is the registry key its resolver looks it up by; a draft is not offered it because there is no session id to rename yet.
    static func overflowActions(isBotThread: Bool, isDraft: Bool, offersTimeline: Bool = false) -> [ChatOverflowAction] {
        var actions: [ChatOverflowAction] = [.details]
        if !isBotThread && !isDraft { actions.append(.rename) }
        actions.append(.project)
        // Only a conversation with prompts in it has anywhere to jump; the demo and a backend without the routes offer nothing.
        if offersTimeline && promptTimelineEnabled { actions.append(.timeline) }
        return actions
    }

    /// The radius the bottom chrome's plate is cut to. Top corners only and full width: a floating full-width surface under a scroll view is what iOS reads as a bottom bar, which reproduces BUG-016.
    static let plateCornerRadius: CGFloat = Radius.sheet

    /// BUG-120: the region the chrome may paint into below the layout bounds. `.container` is the home indicator, and it is neither `.all` nor `.keyboard`, which would re-enter the keyboard's inset negotiation.
    static let homeIndicatorEscape: SafeAreaRegions = .container

    /// Whether the app frosts the region under the top bar itself. Only where the OS does not: on iOS 26 the transcript's scroll view draws its own soft scroll-edge effect there, and a plane over it would hide it.
    static func drawsOwnTopPlane(_ rendering: GlassRendering) -> Bool {
        rendering == .material
    }

    /// What the popover draws: the enabled set, plus the one control that is shown and disabled rather than omitted. A draft's Rename is unavailable only until its first send, so it is greyed; a bot thread's is wrong forever, so it is omitted, and the bot rule wins where both apply.
    static func overflowEntries(isBotThread: Bool, isDraft: Bool, offersTimeline: Bool = false) -> [ChatOverflowEntry] {
        let enabled = overflowActions(isBotThread: isBotThread, isDraft: isDraft, offersTimeline: offersTimeline)
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

    /// The frost under both chrome planes. Both cases resolve to the same material: `.ultraThinMaterial` is the thinnest SwiftUI defines, and how much of the transcript shows through is set by the theme tint laid over it (`GlassMetrics.chromeTintOpacity`), not by a thinner material.
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
    /// The top bar. Its own background is declared, and declared visible, on every OS deliberately: letting the system paint its own bar on iOS 26 also hands the bar its scroll-edge behaviour, which changes the geometry `.defaultScrollAnchor(.bottom)` resolves against and reproduces BUG-016. Do not flip it to `.automatic`.
    /// It is declared clear. The transcript's scroll view already runs up under the bar and the status bar (its top content inset is the bar), so the bar only has to stop hiding it: on iOS 26 the scroll view's own soft scroll-edge effect then frosts and fades the conversation under Back and `⋯`, which is the system's Liquid Glass top edge; below 26 `chatGlassTopPlane()` frosts it instead. The material this used to paint sat over that effect and turned it into a grey slab (BUG-061).
    func chatGlassNavigationBar() -> some View {
        toolbarBackground(Color.clear, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
    }

    /// The frost under the top bar where the OS draws none: a `GlassPlaneBackground` whose rounded edge sits on the top of the conversation and which reaches up past the bar and the status bar and off the screen. Drawn only when the glass resolves to `.material` (iOS 17 to 25, or the forced fallback); on iOS 26 it would bury the system's own scroll-edge effect.
    /// Apply it outside the connection banner's `safeAreaInset`, so the plane ends where the bar ends rather than where the banner does. Layout-neutral: an overlay moved by an offset, which moves drawing and nothing else. In demo mode the demo marker is raised above it (`demoModeMarker`).
    func chatGlassTopPlane() -> some View {
        overlay(alignment: .top) {
            if ChatChrome.drawsOwnTopPlane(GlassRendering.current) {
                GlassPlaneBackground(anchoredTo: .top, cornerRadius: ChatChrome.plateCornerRadius)
                    .frame(height: GlassMetrics.topPlaneReach)
                    .offset(y: -GlassMetrics.topPlaneReach)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    /// One frosted plane for the whole bottom stack rather than one per row, so a row appearing does not put a second frost over the first; the rows on it paint no ground of their own. A material and never `glassEffect`: a full-width `glassEffect` directly beneath a scroll view is read as a bottom bar, which reproduces BUG-016.
    func chatGlassChrome() -> some View {
        background {
            GlassPlaneBackground(anchoredTo: .bottom, cornerRadius: ChatChrome.plateCornerRadius)
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

    /// What the conversation header draws on its second line; nil draws nothing. The line is laid out in every state, so the header's height never changes when the answer lands, but an unresolved project is left blank rather than drawn as a bare em dash, which under a title reads as a rendering fault. `text` keeps the dash for the places that show a value cell.
    var headerText: String? {
        self == .unknown ? nil : text
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

    /// The latest resolve's ticket. Only the resolve holding it may write, because the request does not stop when its task is cancelled and an overtaken answer can arrive last (BUG-093's race).
    private var generation = 0

    func resolve(cwd: String, isConnected: Bool, forCwd: ForCwd?) async {
        generation += 1
        let ticket = generation
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
        guard ticket == generation, !Task.isCancelled else { return }
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
