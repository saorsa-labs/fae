import AppKit
import Combine
import Foundation

/// UX W1: the seam InputRequestBridge uses to prefer the pill for a
/// `request_input` (Fae asks her question INSIDE the conversation surface)
/// instead of the SwiftUI overlay card. RustUiShellController conforms; a mock
/// stands in for it under test.
@MainActor
protocol PillInputRouting: AnyObject {
    /// True when the orb host is running and can host the prompt in the pill.
    var isOrbHostConnected: Bool { get }
    /// Send the request into the pill composer (prompted / masked mode).
    func requestPillInput(
        requestId: String,
        prompt: String,
        secure: Bool,
        multiline: Bool,
        placeholder: String
    )
}

/// UX W1: process-wide registration point so the (actor-isolated)
/// InputRequestBridge can reach the live orb-host controller without a hard
/// dependency. Set once at app startup; nil when the orb host isn't wired.
@MainActor
enum PillInputRouter {
    static weak var shared: (any PillInputRouting)?
}

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
final class RustUiShellController: PillInputRouting {
    weak var orbState: OrbStateController?
    weak var conversation: ConversationRuntimeController?
    weak var faeCore: FaeCore?

    var onSettings: (() -> Void)?
    var onSettingsLegacy: (() -> Void)?
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

    // MARK: - PillInputRouting (UX W1)

    var isOrbHostConnected: Bool { isActive }

    /// Send a `request_input` into the pill composer. The pill acks
    /// (`.faePillInputAck`) then answers with `input_response`/`input_cancel`,
    /// which `handleShellEvent` forwards to `.faeInputResponse`.
    func requestPillInput(
        requestId: String,
        prompt: String,
        secure: Bool,
        multiline: Bool,
        placeholder: String
    ) {
        var message: [String: Any] = [
            "type": "request_input",
            "request_id": requestId,
            "prompt": prompt,
            "secure": secure,
            "multiline": multiline,
        ]
        if !placeholder.isEmpty { message["placeholder"] = placeholder }
        send(message)
    }

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
        sendSettingsSnapshot()
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
            .sink { [weak self] mode in
                // `@Published` emits in `willSet`, so `orbState.mode` still holds
                // the OLD value here — we MUST use the emitted `mode`, not re-read
                // the property, or every orb state lands one transition late
                // (generation looked idle; idle stranded a counting Thinking pill).
                self?.sendState(forMode: mode)
            }
            .store(in: &cancellables)

        orbState?.$feeling
            .removeDuplicates()
            .sink { [weak self] feeling in
                // Feeling (the orb's emotion: warmth/concern/…) is a Swift-owned
                // visual signal independent of mode. Send it WITHOUT a `state`
                // field so the orb host leaves its daemon-derived mode untouched
                // (its State handler treats a missing state as mode-no-op).
                self?.sendFeeling(feeling)
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

        NotificationCenter.default.publisher(for: .faeSettingsChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.sendControlsSnapshot()
                self?.sendSettingsSnapshot()
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

        // Voice spine V4 RETIRED (orb-host-owns-state, 2026-06-17): the orb
        // host now subscribes to the daemon's `audio.level` / `audio.playback_
        // ended` events ITSELF (daemon_audio_bridge.rs) and rides its own voice
        // — Swift no longer relays daemon RMS via `state.audio`. The old
        // `.faeDaemonAudioLevel` / `.faeDaemonAudioEnded` subscriptions +
        // `sendAudioLevel` are gone (they duplicated what the host now owns and
        // re-introduced risk of the orb following two audio sources).
    }

    private func sendStateForCurrentOrbMode() {
        sendState(forMode: orbState?.mode ?? .idle)
    }

    /// Orb-host-owns-state: Swift forwards ONLY the listening/PTT mode to the
    /// orb host (Right-⌥ push-to-talk is a Swift `NSEvent` the host can't see).
    /// The thinking / speaking / quiescent modes are owned by the host's own
    /// grace-hold state machine (driven by daemon events), so we deliberately
    /// do NOT send state commands for them — doing so would fight/override the
    /// host and re-introduce the mid-turn flicker. The host recovers from
    /// `listening` on its own when the next daemon event arrives.
    private func sendState(forMode mode: OrbMode, feeling: OrbFeeling? = nil) {
        switch mode {
        case .listening:
            // The one remaining Swift→orb mode signal (PTT capture).
            sendState("listening", feeling: feeling)
        case .thinking, .speaking, .idle:
            // Owned by the orb host — do not forward. We still forward a feeling
            // change by piggybacking on the host's current mode is not possible
            // here (we don't know it), so feeling updates route via the
            // dedicated feeling channel below.
            break
        }
    }

    private func sendState(_ state: String, feeling: OrbFeeling? = nil) {
        var message: [String: Any] = ["type": "state", "state": state]
        // Butler demeanor: the fog shows emotion (thinking, warmth, concern…).
        // Use the explicitly-passed feeling when present (the $feeling sink
        // observes a willSet, so reading orbState.feeling there is stale).
        if let feeling = (feeling ?? orbState?.feeling)?.rawValue {
            message["feeling"] = feeling
        }
        send(message)
    }

    /// Orb-host-owns-state: forward an emotion change WITHOUT a `state` field.
    /// The orb host's State handler treats a missing state as a mode no-op, so
    /// this updates only the orb's feeling (palette/emotion) and leaves the
    /// daemon-derived thinking/speaking/quiescent mode untouched.
    private func sendFeeling(_ feeling: OrbFeeling?) {
        guard let feeling = feeling?.rawValue else { return }
        send(["type": "state", "feeling": feeling])
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

    private func sendSettingsSnapshot() {
        guard let faeCore else { return }
        var snapshot = faeCore.settingsSnapshot()
        snapshot["type"] = "settings_snapshot"
        send(snapshot)
        let sectionCount = (snapshot["sections"] as? [[String: Any]])?.count ?? 0
        let cardCount = (snapshot["cards"] as? [[String: Any]])?.count ?? 0
        NSLog(
            "RustUiShellController: settings_snapshot sent sections=%d cards=%d",
            sectionCount,
            cardCount
        )
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
        case "input_ack":
            // UX W1: the pill accepted a `request_input` — tell the bridge so it
            // commits to the pill path (a 5s ack timeout falls back to overlay).
            guard let requestId = event.requestId, !requestId.isEmpty else { return }
            NotificationCenter.default.post(
                name: .faePillInputAck,
                object: nil,
                userInfo: ["request_id": requestId]
            )
        case "input_response", "input_cancel":
            // UX W1: the pill composer answered (or cancelled) a `request_input`.
            // Resolve the same continuation the overlay would — a cancel is an
            // empty response (InputRequestBridge maps empty → nil).
            guard let requestId = event.requestId, !requestId.isEmpty else { return }
            let text = (event.type == "input_cancel") ? "" : (event.text ?? "")
            NotificationCenter.default.post(
                name: .faeInputResponse,
                object: nil,
                userInfo: ["request_id": requestId, "text": text]
            )
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
        case "settings_request_snapshot":
            sendSettingsSnapshot()
        case "settings_set":
            guard let key = event.key, let value = event.value else {
                NSLog("RustUiShellController: settings_set missing key/value")
                return
            }
            NSLog("RustUiShellController: settings_set received key=%@", key)
            applySettingsPanelValue(key: key, rawValue: value)
        default:
            NSLog("RustUiShellController: unknown shell event type %@", event.type)
        }
    }

    private func applySettingsPanelValue(key: String, rawValue: String) {
        guard let faeCore else { return }
        guard let value = Self.coerceSettingsPanelValue(key: key, rawValue: rawValue) else {
            NSLog("RustUiShellController: rejected settings_set key=%@ value=%@", key, rawValue)
            sendSettingsSnapshot()
            return
        }
        faeCore.patchConfig(key: key, payload: ["value": value])
        NSLog("RustUiShellController: settings_set applied key=%@", key)
        sendSettingsSnapshot()
    }

    private static func coerceSettingsPanelValue(key: String, rawValue: String) -> Any? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        switch key {
        case "tool_mode":
            let migrated = FaeConfig.migrateToolMode(trimmed)
            return ["assistant", "full"].contains(migrated) ? migrated : nil
        case "llm.thinking_level":
            return FaeThinkingLevel(rawValue: trimmed)?.rawValue
        case "privacy.mode":
            return ["strict_local", "local_preferred", "connected"].contains(trimmed) ? trimmed : nil
        case "awareness.pause_on_battery", "awareness.pause_on_thermal_pressure":
            if trimmed == "true" { return true }
            if trimmed == "false" { return false }
            return nil
        case "awareness.camera_interval_seconds":
            guard let interval = Int(trimmed), [10, 30, 60, 120].contains(interval) else { return nil }
            return interval
        case "awareness.screen_interval_seconds":
            guard let interval = Int(trimmed), [10, 19, 30, 60].contains(interval) else { return nil }
            return interval
        case "tts.speed":
            guard let speed = Double(trimmed), (0.7 ... 1.4).contains(speed) else { return nil }
            return speed
        case "llm.temperature":
            guard let temperature = Double(trimmed), (0.3 ... 1.0).contains(temperature) else { return nil }
            return temperature
        default:
            return nil
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
        case "settings": sendSettingsSnapshot()
        case "settings_legacy": onSettingsLegacy?()
        case "talk_toggle":
            NSLog("RustUiShellController: talk_toggle received")
            onTalkToggle?()
        case "talk_start":
            NSLog("RustUiShellController: talk_start received")
            onTalkStart?()
        case "talk_stop":
            NSLog("RustUiShellController: talk_stop received")
            onTalkStop?()
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
    let key: String?
    let value: String?
    /// UX W1: the pill's `request_input` reply carries the originating id so the
    /// InputRequestBridge resolves the right suspended continuation.
    let requestId: String?

    private enum CodingKeys: String, CodingKey {
        case type, action, id, enabled, active, text, key, value
        case requestId = "request_id"
    }
}
