import AppKit
import Combine
import Foundation

/// Launches and bridges the Rust orb UI host (`native/rust/fae-ui-shell`).
///
/// Product-wise, the orb is the UI; this process is the implementation host for
/// the orb window, status affordance, transcript, menu, and temporary panels.
///
/// The host speaks newline-delimited JSON:
/// - Swift -> host stdin: state/status/conversation/show/hide/quit commands
/// - host stdout -> Swift: menu action events
///
/// Logs from the host are left on stderr so stdout remains machine-readable.
@MainActor
final class RustUiShellController {
    weak var orbState: OrbStateController?
    weak var conversation: ConversationController?
    weak var faeCore: FaeCore?

    var onSettings: (() -> Void)?
    var onResetConversation: (() -> Void)?
    var onHideFae: (() -> Void)?
    var onQuit: (() -> Void)?
    var onPermissionMicrophone: (() -> Void)?
    var onPermissionContacts: (() -> Void)?
    var onPermissionCalendars: (() -> Void)?
    var onPermissionReminders: (() -> Void)?
    var onPermissionMailNotes: (() -> Void)?
    var onOpenPrivacySecurity: (() -> Void)?
    var onScheduler: (() -> Void)?
    var onSkills: (() -> Void)?
    var onEditSoul: (() -> Void)?
    var onEditCustomInstructions: (() -> Void)?
    var onAskFae: (() -> Void)?
    var onAskAboutShortcuts: (() -> Void)?
    var onAskAboutModels: (() -> Void)?
    var onAskAboutPrivacy: (() -> Void)?
    var onAskAboutTools: (() -> Void)?
    var onMemoryInbox: (() -> Void)?
    var onRescueMode: (() -> Void)?

    /// Called when the orb host exits with a non-zero status so the app can
    /// fall back to the Swift window instead of leaving Fae invisible.
    var onUnexpectedExit: (() -> Void)?

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdoutBuffer = Data()
    private var cancellables: Set<AnyCancellable> = []

    /// True while the Rust orb host process is running. When active, the orb
    /// is the product UI and the Swift main window stays hidden.
    var isActive: Bool { process != nil }

    func startIfAvailable() {
        guard process == nil else { return }
        guard let binaryURL = resolveShellBinary() else {
            NSLog("RustUiShellController: shell binary not found; set FAE_UI_SHELL_BIN or run `just build-ui-shell`")
            return
        }

        let process = Process()
        process.executableURL = binaryURL

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.handleStdout(data)
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            NSLog("RustUiShell stderr: %@", text.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        process.terminationHandler = { [weak self] terminated in
            Task { @MainActor [weak self] in
                self?.process = nil
                self?.stdinPipe = nil
                self?.stdoutPipe = nil
                self?.stderrPipe = nil
                if terminated.terminationStatus == 0 {
                    NSLog("RustUiShellController: orb host exited status=%d", terminated.terminationStatus)
                } else {
                    NSLog("RustUiShellController: orb host exited unexpectedly status=%d", terminated.terminationStatus)
                    self?.onUnexpectedExit?()
                }
            }
        }

        do {
            try process.run()
        } catch {
            NSLog("RustUiShellController: failed to launch shell at %@: %@", binaryURL.path, String(describing: error))
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            return
        }

        self.process = process
        self.stdinPipe = stdinPipe
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
        observeBridgeSources()
        sendStateForCurrentOrbMode()
        sendRuntimeStatus()
        sendConversationSnapshot()
        refreshWorkspaceSnapshot()
    }

    func stop() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        send(["type": "quit"])
        process?.terminate()
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        cancellables.removeAll()
    }

    private func observeBridgeSources() {
        cancellables.removeAll()
        orbState?.$mode
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.sendStateForCurrentOrbMode()
            }
            .store(in: &cancellables)

        orbState?.$feeling
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.sendStateForCurrentOrbMode()
            }
            .store(in: &cancellables)

        faeCore?.$pipelineState
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.sendRuntimeStatus()
                self?.refreshWorkspaceSnapshot()
            }
            .store(in: &cancellables)

        conversation?.$loadedModelLabel
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.sendRuntimeStatus()
            }
            .store(in: &cancellables)

        conversation?.$messages
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] messages in
                self?.sendConversationSnapshot(messages)
            }
            .store(in: &cancellables)
    }

    private func sendStateForCurrentOrbMode() {
        guard let mode = orbState?.mode else {
            sendState("quiescent")
            return
        }

        switch mode {
        case .thinking:
            sendState("thinking")
        case .speaking:
            sendState("speaking")
        case .idle, .listening:
            // Product UX: no visible orb while idle/quiescent or merely listening.
            sendState("quiescent")
        }
    }

    private func sendState(_ state: String) {
        var message: [String: Any] = ["type": "state", "state": state]
        // Butler demeanor: the fog shows emotion (thinking, warmth, concern…).
        if let feeling = orbState?.feeling.rawValue {
            message["feeling"] = feeling
        }
        send(message)
    }

    func refreshWorkspaceSnapshot() {
        Task { @MainActor [weak self] in
            await self?.sendWorkspaceSnapshot()
        }
    }

    private func sendRuntimeStatus() {
        let phase = faeCore?.pipelineState.rawValue ?? "starting"
        let model = conversation?.loadedModelLabel.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let message: String
        let progress: Double?
        switch faeCore?.pipelineState {
        case .starting:
            message = model.isEmpty ? "Starting local runtime" : "Loading \(model)"
            progress = 0.35
        case .running:
            message = model.isEmpty ? "Ready" : "Ready · \(model)"
            progress = 1.0
        case .stopping:
            message = "Stopping"
            progress = nil
        case .stopped:
            message = "Stopped"
            progress = nil
        case .error:
            message = "Runtime needs attention"
            progress = nil
        case nil:
            message = "Starting Fae"
            progress = nil
        }
        var object: [String: Any] = ["type": "status", "phase": phase, "message": message]
        if let progress { object["progress"] = progress }
        send(object)
    }

    private func sendWorkspaceSnapshot() async {
        guard let faeCore else { return }
        let snapshot = await faeCore.workspaceSnapshot()
        let formatter = ISO8601DateFormatter()
        let tasks = WorkspaceSchedulerTask.load(statusesByID: snapshot.schedulerStatusesByID)
            .map { task -> [String: Any] in
                var object: [String: Any] = [
                    "id": task.id,
                    "name": task.name,
                    "schedule": task.scheduleDescription,
                    "enabled": task.enabled,
                    "status": task.enabled ? "enabled" : "disabled",
                ]
                if let lastRun = task.lastRun {
                    object["last_run"] = formatter.string(from: lastRun)
                }
                if let nextRun = task.nextRun {
                    object["next_run"] = formatter.string(from: nextRun)
                }
                return object
            }
        send(["type": "scheduler_snapshot", "tasks": tasks])

        let skills = snapshot.skills.map { skill -> [String: Any] in
            [
                "id": skill.id,
                "description": skill.description,
                "skill_type": skill.type,
                "tier": skill.tier,
                "enabled": skill.isEnabled,
                "active": skill.isActive,
            ]
        }
        send(["type": "skills_snapshot", "skills": skills])
    }

    private func sendConversationSnapshot(_ messages: [ChatMessage]? = nil) {
        send(["type": "clear_conversation"])
        let snapshot = (messages ?? conversation?.messages ?? []).suffix(40)
        for message in snapshot {
            let role: String
            switch message.role {
            case .user: role = "user"
            case .assistant: role = "fae"
            case .tool: role = "tool"
            case .summary: role = "summary"
            }
            send(["type": "conversation", "role": role, "text": message.content])
        }
    }

    private func send(_ object: [String: Any]) {
        guard let stdinPipe else { return }
        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: [])
            stdinPipe.fileHandleForWriting.write(data)
            stdinPipe.fileHandleForWriting.write(Data([0x0A]))
        } catch {
            NSLog("RustUiShellController: failed to encode bridge command: %@", String(describing: error))
        }
    }

    private func handleStdout(_ data: Data) {
        stdoutBuffer.append(data)
        if stdoutBuffer.count > 1_048_576 {
            NSLog("RustUiShellController: stdout buffer exceeded 1 MiB without draining; clearing")
            stdoutBuffer.removeAll(keepingCapacity: true)
            return
        }
        while let newline = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer[..<newline]
            stdoutBuffer.removeSubrange(...newline)
            guard !lineData.isEmpty else { continue }
            handleStdoutLine(Data(lineData))
        }
    }

    private func handleStdoutLine(_ data: Data) {
        do {
            let event = try JSONDecoder().decode(ShellEvent.self, from: data)
            handleShellEvent(event)
        } catch {
            let raw = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            NSLog("RustUiShellController: invalid shell stdout JSON %@: %@", raw, String(describing: error))
        }
    }

    private func handleShellEvent(_ event: ShellEvent) {
        switch event.type {
        case "menu":
            handleMenuAction(event.action ?? "")
        case "scheduler_toggle":
            guard let id = event.id, let enabled = event.enabled else {
                NSLog("RustUiShellController: scheduler_toggle missing id/enabled")
                return
            }
            setSchedulerTask(id: id, enabled: enabled)
        case "skill_toggle":
            guard let id = event.id, let active = event.active else {
                NSLog("RustUiShellController: skill_toggle missing id/active")
                return
            }
            setSkill(id: id, active: active)
        default:
            NSLog("RustUiShellController: unknown shell event type %@", event.type)
        }
    }

    private func setSchedulerTask(id: String, enabled: Bool) {
        var tasks = readSchedulerTasks()
        if let index = tasks.firstIndex(where: { $0.id == id }) {
            tasks[index].enabled = enabled
        } else {
            tasks.append(SchedulerTask(
                id: id,
                name: id.split(separator: "_").map { $0.capitalized }.joined(separator: " "),
                kind: "builtin",
                enabled: enabled,
                scheduleType: "builtin",
                scheduleParams: [:],
                action: id,
                taskDescription: nil,
                instructionBody: nil,
                nextRun: nil,
                allowedTools: nil
            ))
        }
        do {
            try writeSchedulerTasks(tasks)
        } catch {
            NSLog("RustUiShellController: failed to persist scheduler toggle for %@: %@", id, String(describing: error))
        }
        refreshWorkspaceSnapshot()
    }

    private func setSkill(id: String, active: Bool) {
        guard let faeCore else { return }
        Task { @MainActor [weak self] in
            await faeCore.setSkill(id, active: active)
            self?.refreshWorkspaceSnapshot()
        }
    }

    private func handleMenuAction(_ action: String) {
        switch action {
        case "settings": onSettings?()
        case "open_browser_data_panel", "show_messages": break // Handled inside the orb host.
        case "reset_conversation":
            send(["type": "clear_conversation"])
            onResetConversation?()
        case "hide_fae":
            sendState("quiescent")
            onHideFae?()
        case "stop": NotificationCenter.default.post(name: .faeCancelGeneration, object: nil)
        case "permissions_microphone": onPermissionMicrophone?()
        case "permissions_contacts": onPermissionContacts?()
        case "permissions_calendars": onPermissionCalendars?()
        case "permissions_reminders": onPermissionReminders?()
        case "permissions_mail_notes": onPermissionMailNotes?()
        case "open_privacy_security": onOpenPrivacySecurity?()
        case "scheduler": onScheduler?()
        case "skills": onSkills?()
        case "edit_soul": onEditSoul?()
        case "edit_custom_instructions": onEditCustomInstructions?()
        case "ask_fae": onAskFae?()
        case "ask_about_shortcuts": onAskAboutShortcuts?()
        case "ask_about_models": onAskAboutModels?()
        case "ask_about_privacy": onAskAboutPrivacy?()
        case "ask_about_tools": onAskAboutTools?()
        case "memory_inbox": onMemoryInbox?()
        case "rescue_mode": onRescueMode?()
        case "quit": onQuit?()
        default:
            NSLog("RustUiShellController: unhandled menu action %@", action)
        }
    }

    private func resolveShellBinary() -> URL? {
        let env = ProcessInfo.processInfo.environment
        if let configured = env["FAE_UI_SHELL_BIN"], !configured.isEmpty {
            let url = URL(fileURLWithPath: configured)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }

        let bundledCandidate = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/fae-ui-shell")
        if FileManager.default.isExecutableFile(atPath: bundledCandidate.path) {
            return bundledCandidate
        }

        let cwdCandidate = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("native/rust/fae-ui-shell/target/release/fae-ui-shell")
        if FileManager.default.isExecutableFile(atPath: cwdCandidate.path) {
            return cwdCandidate
        }

        return nil
    }
}

private struct ShellEvent: Decodable {
    let type: String
    let action: String?
    let id: String?
    let enabled: Bool?
    let active: Bool?
}
