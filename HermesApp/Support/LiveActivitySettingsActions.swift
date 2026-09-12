import Foundation
import HermesServeKit

/// Every write Settings → Notifications makes to the Live Activity preferences (FEAT-019): write the preference, then make the glass agree now, because an off switch that waits for the end of the turn is not an off switch.
@MainActor
enum LiveActivitySettingsActions {

    /// The master. Off means nothing on either surface, at once.
    static func setMaster(_ isOn: Bool, controller: LiveActivityController = .shared) {
        LiveActivityPreferences.enabled = isOn
        settle(controller: controller, reason: "master toggle")
    }

    /// Fill the Lock Screen card, or empty it; off with the island still on leaves the activity running, because the island is the same activity.
    static func setLockScreen(_ isOn: Bool, controller: LiveActivityController = .shared) {
        LiveActivityPreferences.lockScreen = isOn
        settle(controller: controller, reason: "Lock Screen toggle")
    }

    /// Draw in the Dynamic Island, or draw nothing there; off with the Lock Screen still on leaves the activity running for the same reason.
    static func setIsland(_ isOn: Bool, controller: LiveActivityController = .shared) {
        LiveActivityPreferences.island = isOn
        settle(controller: controller, reason: "Dynamic Island toggle")
    }

    /// Which turns earn a card; narrowing it takes the cards that no longer qualify off the glass at once, rather than when their turns happen to finish.
    static func setShowPolicy(_ policy: LiveActivityShowPolicy, controller: LiveActivityController = .shared) {
        LiveActivityPreferences.showPolicy = policy
        settle(controller: controller, reason: "when-to-show")
    }

    /// The auto-start row for unattended runs.
    static func setAutoStartForCron(_ isOn: Bool, controller: LiveActivityController = .shared) {
        LiveActivityPreferences.autoStartForCron = isOn
        settle(controller: controller, reason: "cron auto-start")
    }

    private static func settle(controller: LiveActivityController, reason: String) {
        if LiveActivityPreferences.presentationAllowed {
            controller.reconcile()
        } else {
            controller.endAll(reason: reason)
        }
    }
}
