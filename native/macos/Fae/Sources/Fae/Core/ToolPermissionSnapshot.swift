import Foundation

/// Unified runtime snapshot of tool availability and OS permission state.
///
/// Used by pipeline voice commands, canvas rendering, and settings diagnostics to
/// present one coherent view of Fae's current authority envelope.
struct ToolPermissionSnapshot: Sendable {
    struct PermissionAction: Sendable {
        let label: String
        let capability: String
    }

    let generatedAt: Date
    let triggerText: String
    let toolMode: String
    let policyProfile: String
    let speakerState: String
    let ownerGateEnabled: Bool
    let ownerProfileExists: Bool
    let permissions: PermissionStatusProvider.Snapshot
    let thinkingEnabled: Bool
    let bargeInEnabled: Bool
    let requireDirectAddress: Bool
    let visionEnabled: Bool
    let voiceIdentityLock: Bool
    let allowedTools: [String]
    let deniedTools: [String]

    var missingPermissionActions: [PermissionAction] {
        var actions: [PermissionAction] = []
        if !permissions.microphone {
            actions.append(.init(label: "Microphone", capability: "microphone"))
        }
        if !permissions.contacts {
            actions.append(.init(label: "Contacts", capability: "contacts"))
        }
        if !permissions.calendar {
            actions.append(.init(label: "Calendar", capability: "calendar"))
        }
        if !permissions.reminders {
            actions.append(.init(label: "Reminders", capability: "reminders"))
        }
        if !permissions.camera {
            actions.append(.init(label: "Camera", capability: "camera"))
        }
        if !permissions.screenRecording {
            actions.append(.init(label: "Screen Recording", capability: "screen_recording"))
        }
        return actions
    }

    func toCanvasHTML() -> String {
        func badge(_ granted: Bool) -> String {
            granted
                ? "<span class='ok'>granted</span>"
                : "<span class='warn'>not granted</span>"
        }

        func listItems(_ values: [String]) -> String {
            guard !values.isEmpty else { return "<li>None</li>" }
            return values.map { "<li><code>\($0)</code></li>" }.joined()
        }

        let modeActions = """
        <div class='panel'>
          <p><strong>Tool mode quick actions</strong></p>
          <p class='hint'>Click to apply immediately:</p>
          <div class='chips'>
            <a class='chip' href='fae-action://set_tool_mode?value=off&source=canvas'>Off</a>
            <a class='chip' href='fae-action://set_tool_mode?value=read_only&source=canvas'>Read Only</a>
            <a class='chip' href='fae-action://set_tool_mode?value=read_write&source=canvas'>Read/Write</a>
            <a class='chip' href='fae-action://set_tool_mode?value=full&source=canvas'>Full</a>
            <a class='chip danger' href='fae-action://set_tool_mode?value=full_no_approval&source=canvas'>Full (No Approval)</a>
          </div>
        </div>
        """

        let behaviorActions = """
        <div class='panel'>
          <p><strong>Behavior quick actions</strong></p>
          <div class='chips'>
            <a class='chip' href='fae-action://set_setting?key=llm.thinking_enabled&value=\(thinkingEnabled ? "false" : "true")&source=canvas'>Thinking \(thinkingEnabled ? "ON" : "OFF")</a>
            <a class='chip' href='fae-action://set_setting?key=barge_in.enabled&value=\(bargeInEnabled ? "false" : "true")&source=canvas'>Barge-in \(bargeInEnabled ? "ON" : "OFF")</a>
            <a class='chip' href='fae-action://set_setting?key=conversation.require_direct_address&value=\(requireDirectAddress ? "false" : "true")&source=canvas'>Direct address \(requireDirectAddress ? "ON" : "OFF")</a>
            <a class='chip' href='fae-action://set_setting?key=vision.enabled&value=\(visionEnabled ? "false" : "true")&source=canvas'>Vision \(visionEnabled ? "ON" : "OFF")</a>
            <a class='chip danger' href='fae-action://set_setting?key=tts.voice_identity_lock&value=\(voiceIdentityLock ? "false" : "true")&source=canvas'>Voice lock \(voiceIdentityLock ? "ON" : "OFF")</a>
          </div>
        </div>
        """

        let permissionActions: String = {
            guard !missingPermissionActions.isEmpty else {
                return "<p class='hint'>All tracked permissions are currently granted.</p>"
            }
            let chips = missingPermissionActions.map { action in
                "<a class='chip' href='fae-action://request_permission?capability=\(action.capability)&source=canvas'>Grant \(action.label)</a>"
            }.joined(separator: "")
            return "<div class='chips'>\(chips)</div>"
        }()

        return """
        <html>
        <head>
          <meta name='viewport' content='width=device-width, initial-scale=1' />
          <style>
            body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; background: #0f1015; color: #e9e9ef; padding: 18px; line-height: 1.45; }
            h1 { font-size: 18px; margin: 0 0 8px 0; }
            h2 { font-size: 14px; margin: 14px 0 6px 0; color: #c8b8db; }
            p, li { font-size: 12px; }
            ul { margin: 6px 0 0 0; padding-left: 18px; }
            .panel { border: 1px solid #2a2d38; border-radius: 10px; padding: 10px 12px; margin-bottom: 10px; background: #171a23; }
            .ok { color: #53d18f; font-weight: 600; }
            .warn { color: #f0b46e; font-weight: 600; }
            code { color: #d9c8ea; }
            .hint { color: #99a0b6; }
            .chips { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 8px; }
            .chip { font-size: 11px; text-decoration: none; color: #e9e9ef; border: 1px solid #3d4354; padding: 5px 9px; border-radius: 999px; background: #202533; }
            .chip:hover { border-color: #8b94ad; }
            .chip.danger { border-color: #87545a; color: #ffcbcf; }
          </style>
        </head>
        <body>
          <h1>Tools & Permission Snapshot</h1>
          <div class='panel'>
            <p><strong>Trigger:</strong> \(triggerText)</p>
            <p><strong>Tool mode:</strong> <code>\(toolMode)</code> · <strong>Policy:</strong> <code>\(policyProfile)</code></p>
            <p><strong>Speaker trust:</strong> \(speakerState)</p>
            <p><strong>Owner gate:</strong> \(ownerGateEnabled ? "enabled" : "disabled") · owner profile \(ownerProfileExists ? "present" : "missing")</p>
            <p><strong>Behavior:</strong> thinking \(thinkingEnabled ? "on" : "off") · barge-in \(bargeInEnabled ? "on" : "off") · direct-address \(requireDirectAddress ? "on" : "off") · vision \(visionEnabled ? "on" : "off") · voice lock \(voiceIdentityLock ? "on" : "off")</p>
          </div>

          \(modeActions)
          \(behaviorActions)

          <h2>System permissions</h2>
          <div class='panel'>
            <p>Microphone: \(badge(permissions.microphone))</p>
            <p>Contacts: \(badge(permissions.contacts))</p>
            <p>Calendar: \(badge(permissions.calendar))</p>
            <p>Reminders: \(badge(permissions.reminders))</p>
            <p>Camera: \(badge(permissions.camera))</p>
            <p>Screen Recording: \(badge(permissions.screenRecording))</p>
            \(permissionActions)
          </div>

          <h2>Allowed tools (\(allowedTools.count))</h2>
          <div class='panel'>
            <ul>\(listItems(allowedTools))</ul>
          </div>

          <h2>Not available in this mode (\(deniedTools.count))</h2>
          <div class='panel'>
            <ul>\(listItems(deniedTools))</ul>
          </div>

          <p class='hint'>Voice commands: “set tool mode to read only”, “enable thinking mode”, “request camera permission”, “lock your voice”.</p>
        </body>
        </html>
        """
    }
}
