import Foundation
import HermesServeKit

/// How a Stop aimed at a live session row must be delivered (BUG-032); in a chat `isForeignStop == false` means "I started this", while for a row this phone never sent into it means "I have no idea".
enum SessionStopRoute: Equatable {
    case stopAttendedChat
    case confirmThenStopAttendedChat
    /// No chat on this phone owns this session, so nothing here can prove the turn is ours; this is the default for the unknowable case, because `turnStartedLocally` reads false for an untracked session exactly as it does for a foreign turn.
    case confirmThenStopUnattended

    var needsConfirmation: Bool { self != .stopAttendedChat }
}

extension AppModel {
    /// Who owns the turn on a live session row, as far as this client can prove, expressed as how its Stop must be delivered; `session.active_list` carries no ownership field at all, so everything else asks.
    func stopRoute(forRuntimeSessionID sessionID: String) -> SessionStopRoute {
        guard let chat = chat(runtimeSessionID: sessionID) else {
            return .confirmThenStopUnattended
        }
        return chat.isForeignStop ? .confirmThenStopAttendedChat : .stopAttendedChat
    }

    /// Stop a live session this phone is not attending, through the optimistic finalise, the publish and the delegated-agent leg (BUG-013), but never the resume-and-retry repair, which would bind the session as a side effect nobody asked for.
    func stopUnattendedSession(runtimeSessionID sessionID: String) async throws {
        guard let sessionAPI else { throw HermesError.notConnected }

        // Sampled BEFORE the finalise: `markInterrupted` clears the whole activity surface on its way past, and these ids are the only route back to agents the session interrupt does not touch.
        let isTracked = engine.trackedSessionIDs.contains(sessionID)
        let agentIDs = isTracked ? engine.state(for: sessionID).activity.interruptibleSubagentIDs : []

        // Only when the engine already holds state: `markInterrupted` on an untracked id would create a roster entry `isQuiescent` then refuses to evict, the per-tap leak BUG-004 exists to prevent.
        if isTracked {
            engine.markInterrupted(sessionID: sessionID)
            publish(sessionID: sessionID)
        }

        do {
            try await sessionAPI.interrupt(sessionID: sessionID)
        } catch let error as HermesError where error.isSessionNotFound {
            // The row is already gone, and surfacing that under a row the user just asked to stop reads as a failure when it is a success.
        }

        // After the turn, never racing it: the turn dies first so it cannot dispatch another fan-out into the window.
        for agentID in agentIDs {
            _ = try? await sessionAPI.interruptSubagent(subagentID: agentID, sessionID: sessionID)
        }
    }
}
