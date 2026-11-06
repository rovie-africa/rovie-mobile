//
//  ActivityOffloadBridge.swift
//  MinisApp
//
//  Swift bridge for apple-activity offload — enables the guest agent to
//  directly update the Dynamic Island and Lock Screen Live Activity.
//

import Foundation
import ActivityKit

@objc public class ActivityOffloadBridge: NSObject {

    @objc public static func isAvailable() -> Bool {
        if #available(iOS 16.2, *) {
            return AgentLiveActivityManager.shared.isAvailable
        }
        return false
    }

    @objc public static func updateStatus(status: String, icon: String, title: String) -> Bool {
        guard #available(iOS 16.2, *) else { return false }
        let toolIcon = icon.isEmpty ? "sparkles" : icon
        let snapshot = LiveSessionSnapshot(
            sessionId: "agent-session",
            title: title.isEmpty ? "Rovie Task" : title,
            toolIcon: toolIcon,
            toolStatus: status,
            loopIteration: 1,
            isCompleted: false,
            lastMessage: ""
        )

        Task { @MainActor in
            AgentLiveActivityManager.shared.startActivity(sessions: [snapshot])
            AgentLiveActivityManager.shared.updateActivity(sessions: [snapshot])
        }
        return true
    }

    @objc public static func finishActivity(message: String) -> Bool {
        guard #available(iOS 16.2, *) else { return false }
        Task { @MainActor in
            await AgentLiveActivityManager.shared.finishActivity(lastMessages: ["agent-session": message])
        }
        return true
    }

    @objc public static func endActivity() -> Bool {
        guard #available(iOS 16.2, *) else { return false }
        Task { @MainActor in
            AgentLiveActivityManager.shared.endActivity()
        }
        return true
    }
}
