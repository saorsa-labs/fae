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
    /// Plain left-click on the orb body (S18 push-to-talk toggle).
    var onTalkToggle: (() -> Void)?
    /// Orb long-press gesture: hold starts capture, release sends.
    var onTalkStart: (() -> Void)?
    var onTalkStop: (() -> Void)?
    /// Text submitted from the messages-panel composer.
    var onSendText: ((String) -> Void)?
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

    /// Called after the orb host has crashed repeatedly and automatic
    /// restarts are exhausted. The app shows a Retry/Quit alert — the orb
    /// host is the only product UI, so there is no window fallback.
    var onRestartExhausted: (() -> Void)?

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdoutBuffer = Data()
    private var cancellables: Set<AnyCancellable> = []

    /// Overall startup fraction (monotonic max of runtimeProgress events) —
    /// shown by the whisper pill + Messages status chip while starting.
    private var startupProgress: Double = 0

    /// Pipeline state as received from the `$pipelineState` sink. @Published
    /// publishers fire BEFORE the property is written, so re-reading
    /// `faeCore?.pipelineState` inside the sink sees the STALE value — that
    /// kept the pill saying "Loading … 100%" forever after startup finished.
    private var lastPipelineState: FaePipelineState?

    // MARK: - Crash Restart Policy

    /// Maximum automatic restarts after unexpected exits before asking the
    /// user. Reset whenever the host stays alive for `stableRunInterval`.
    private static let maxRestartAttempts = 3
    /// A run longer than this is considered stable and resets the counter.
    private static let stableRunInterval: TimeInterval = 60
    private var restartAttempts = 0
    private var lastLaunchDate: Date?
    /// Set during `stop()` so an intentional shutdown never triggers restart.
    private var isStoppingIntentionally = false
    private var pendingRestartTask: Task<Void, Never>?

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
                guard let self else { return }
                self.process = nil
                self.stdinPipe = nil
                self.stdoutPipe = nil
                self.stderrPipe = nil
                if self.isStoppingIntentionally || terminated.terminationStatus == 0 {
                    NSLog("RustUiShellController: orb host exited status=%d", terminated.terminationStatus)
                } else {
                    NSLog("RustUiShellController: orb host exited unexpectedly status=%d", terminated.terminationStatus)
                    self.scheduleRestartAfterCrash()
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

        lastLaunchDate = Date()
        self.process = process
        self.stdinPipe = stdinPipe
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
        observeBridgeSources()
        sendStateForCurrentOrbMode()
        sendRuntimeStatus()
        sendControlsSnapshot()
        sendConversationSnapshot()
        refreshWorkspaceSnapshot()
    }

    func stop() {
        isStoppingIntentionally = true
        pendingRestartTask?.cancel()
        pendingRestartTask = nil
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

    /// Reset the crash counter and relaunch — used by the Retry alert action.
    func retryAfterExhaustedRestarts() {
        restartAttempts = 0
        isStoppingIntentionally = false
        startIfAvailable()
    }

    /// Restart the orb host after a crash: up to `maxRestartAttempts` times
    /// with exponential backoff (1s, 2s, 4s). A stable run of at least
    /// `stableRunInterval` resets the counter. When attempts are exhausted,
    /// `onRestartExhausted` fires so the app can offer Retry/Quit.
    private func scheduleRestartAfterCrash() {
        // A long stable run means earlier crashes are stale — start fresh.
        if let lastLaunchDate, Date().timeIntervalSince(lastLaunchDate) >= Self.stableRunInterval {
            restartAttempts = 0
        }

        guard restartAttempts < Self.maxRestartAttempts else {
            NSLog("RustUiShellController: orb host crashed %d times — giving up, asking user", restartAttempts)
            onRestartExhausted?()
            return
        }

        restartAttempts += 1
        let backoffSeconds = pow(2.0, Double(restartAttempts - 1)) // 1, 2, 4
        NSLog(
            "RustUiShellController: restarting orb host (attempt %d/%d) in %.0fs",
            restartAttempts, Self.maxRestartAttempts, backoffSeconds
        )
        pendingRestartTask?.cancel()
        pendingRestartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(backoffSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.pendingRestartTask = nil
            self?.startIfAvailable()
        }
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
            .sink { [weak self] state in
                if state == .starting {
                    // Fresh startup (or restart) — progress climbs from zero.
                    self?.startupProgress = 0
                }
                self?.lastPipelineState = state
                self?.sendRuntimeStatus()
                self?.refreshWorkspaceSnapshot()
            }
            .store(in: &cancellables)

        // Real startup progress for the whisper pill + status chip. The model
        // stages emit overall fractions (0.05…1.0); forward the monotonic max
        // so the bar never walks backwards as stages interleave.
        NotificationCenter.default.publisher(for: .faeRuntimeProgress)
            .compactMap { $0.userInfo?["progress"] as? Double }
            .receive(on: RunLoop.main)
            .sink { [weak self] progress in
                guard let self,
                      (self.lastPipelineState ?? self.faeCore?.pipelineState) == .starting
                else { return }
                let next = max(self.startupProgress, min(max(progress, 0), 1))
                // Only re-send when the visible percentage actually moves.
                if Int(next * 100) != Int(self.startupProgress * 100) {
                    self.startupProgress = next
                    self.sendRuntimeStatus()
                } else {
                    self.startupProgress = next
                }
            }
            .store(in: &cancellables)

        // Controls strip (Messages panel): keep the shell's ACCESS/THINKING
        // dropdowns in sync with the live config.
        faeCore?.$toolMode
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.sendControlsSnapshot()
            }
            .store(in: &cancellables)

        faeCore?.$thinkingLevel
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.sendControlsSnapshot()
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
        case .listening:
            // S18 push-to-talk capture in progress — the user needs visible
            // feedback that the mic is live. Nothing else sets this mode.
            sendState("listening")
        case .idle:
            // Product UX: no visible orb while idle/quiescent.
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
        // lastPipelineState is the sink-delivered value; the property read is
        // a fallback for calls outside the sink (panel open, label change).
        let state = lastPipelineState ?? faeCore?.pipelineState
        let phase = state?.rawValue ?? "starting"
        let model = conversation?.loadedModelLabel.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let message: String
        let progress: Double?
        switch state {
        case .starting:
            message = model.isEmpty ? "Starting local runtime" : "Loading \(model)"
            // Real overall startup fraction from runtimeProgress events —
            // nil until the first stage reports, never a fake placeholder.
            progress = startupProgress > 0 ? startupProgress : nil
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

    private func sendControlsSnapshot() {
        guard let faeCore else { return }
        send([
            "type": "controls_snapshot",
            "access": faeCore.toolMode,
            "thinking": faeCore.thinkingLevel.rawValue,
        ])
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
        case "send_text":
            // Messages-panel composer (typed input from the orb's panel).
            guard let text = event.text, !text.isEmpty else { return }
            onSendText?(text)
        case "set_access":
            // Messages-panel Controls strip → tool access mode.
            guard let faeCore, let value = event.value, !value.isEmpty else { return }
            Task { @MainActor in
                faeCore.patchConfig(key: "tool_mode", payload: ["value": value])
            }
        case "set_thinking":
            // Messages-panel Controls strip → reasoning depth.
            guard let faeCore, let value = event.value,
                  let level = FaeThinkingLevel(rawValue: value)
            else { return }
            Task { @MainActor in
                faeCore.setThinkingLevel(level)
            }
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
        case "talk_toggle": onTalkToggle?()
        case "talk_start": onTalkStart?()
        case "talk_stop": onTalkStop?()
        case "open_browser_data_panel", "show_messages": break // Handled inside the orb host.
        case "reset_conversation":
            send(["type": "clear_conversation"])
            onResetConversation?()
        case "hide_fae":
            // Quiescent no longer hides the orb (it must stay clickable for
            // push-to-talk) — hide explicitly.
            send(["type": "hide"])
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
    let text: String?
    let value: String?
}
