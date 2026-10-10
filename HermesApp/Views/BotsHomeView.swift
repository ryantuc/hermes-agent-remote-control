import HermesServeKit
import SwiftUI

/// The Bots root, a Messages-style roster list: what Home is while the app is in Bots mode.
/// It is the `NavigationStack`'s root view, swapped in for `HomeView` by `RootView`, so Back out of a bot thread lands here and not in a Sessions stack.
/// There is no composer: a bot conversation is opened, never started, because a bot's thread is the one session titled `Bot Chat` in its profile and the client must never mint a second one.
@MainActor
struct BotsHomeView: View {
    @Environment(\.hermes) private var t
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @Binding var path: [AppRoute]
    @Binding var hubOpen: Bool
    @Binding var mode: AppMode
    /// `RootView`'s mode switch: it owns `path` and the stashed Sessions path, so the route arithmetic has to happen where both live.
    let onToggleMode: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            topBar

            // The roster polls only while the socket is open, so a closed one would leave the list sitting on "no profiles yet" with nothing said about why.
            if !app.connectionState.isOpen {
                ConnectionBannerView(
                    state: app.connectionState,
                    detail: app.connectionError,
                    onRetry: { Task { await app.connect() } },
                    onOpenSettings: { path.append(contentsOf: [.settings, .settingsBackend]) }
                )
            }

            ScrollView {
                BotRosterList(emptyFillsScreen: true) { bot in
                    // The Bots root is the bottom of this stack, so this is an append and Back returns to the list.
                    path.append(.thread(.bot(bot.threadRef)))
                }
                .padding(.bottom, Space.s10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(t.canvas)
        .toolbar(.hidden, for: .navigationBar)
        // Polling is a foreground-surface cost and is paid only while the surface is up; Sessions mode never polls.
        .onAppear {
            app.bots.setRosterVisible(true)
            Task { await app.bots.refresh() }
        }
        .onDisappear {
            app.bots.setRosterVisible(false)
        }
    }

    // MARK: Top bar — 52 pt, no background, no hairline

    private var topBar: some View {
        HStack(spacing: Space.s4) {
            if horizontalSizeClass == .regular {
                // The rail is already open; the clear slot keeps the title centred, exactly as Home does it.
                Color.clear.frame(width: Hit.min, height: Hit.min)
            } else {
                HomeMenuButton { hubOpen = true }
            }

            Spacer(minLength: 0)
            Text(AppMode.bots.label)
                .font(HermesFont.calloutStrong)
                .foregroundStyle(t.text1)
                .lineLimit(1)
            Spacer(minLength: 0)

            HomeModeControlButton(mode: mode, action: onToggleMode)
        }
        .homeBarRow()
    }
}
