import Foundation

// MARK: - ChannelHealthStatus

/// Health status for a channel adapter.
enum ChannelHealthStatus: Sendable, Equatable, CustomStringConvertible {
    /// Adapter is connected and functioning normally.
    case connected

    /// Adapter is disconnected.
    case disconnected

    /// Adapter is attempting to reconnect.
    case reconnecting(attempt: Int)

    /// Adapter encountered an error.
    case error(String)

    var description: String {
        switch self {
        case .connected: return "connected"
        case .disconnected: return "disconnected"
        case .reconnecting(let attempt): return "reconnecting (attempt \(attempt))"
        case .error(let message): return "error: \(message)"
        }
    }

    /// Whether this status indicates the adapter is healthy.
    var isHealthy: Bool {
        if case .connected = self { return true }
        return false
    }
}

// MARK: - ChannelHealthMonitor

/// Monitors channel adapter health and manages auto-reconnection.
///
/// The monitor periodically checks adapter status and attempts reconnection
/// for adapters that have become disconnected. It uses exponential backoff
/// for retry attempts and reports status via the event bus.
actor ChannelHealthMonitor {
    /// Configuration for the health monitor.
    struct Config: Sendable {
        /// Interval between health checks (seconds).
        var checkIntervalSeconds: TimeInterval = 30.0

        /// Maximum number of reconnection attempts before giving up.
        var maxReconnectAttempts: Int = 5

        /// Base delay for exponential backoff (seconds).
        var baseRetryDelay: TimeInterval = 2.0

        /// Maximum delay between retries (seconds).
        var maxRetryDelay: TimeInterval = 60.0
    }

    private let eventBus: FaeEventBus
    private let config: Config
    private var adapterStates: [ChannelKind: AdapterHealthState] = [:]
    private var monitorTask: Task<Void, Never>?
    private var isRunning = false

    /// Create a new health monitor.
    ///
    /// - Parameters:
    ///   - eventBus: The event bus for emitting health status events.
    ///   - config: Monitor configuration.
    init(eventBus: FaeEventBus, config: Config = Config()) {
        self.eventBus = eventBus
        self.config = config
    }

    // MARK: - Lifecycle

    /// Start periodic health monitoring.
    ///
    /// - Parameter adapters: The adapters to monitor, keyed by channel kind.
    func start(adapters: [ChannelKind: any ChannelAdapter]) {
        guard !isRunning else { return }
        isRunning = true

        // Initialise states for all adapters.
        for (kind, adapter) in adapters {
            adapterStates[kind] = AdapterHealthState(
                adapter: adapter,
                status: .connected,
                reconnectAttempts: 0,
                lastCheck: Date()
            )
        }

        monitorTask = Task { [weak self] in
            await self?.monitorLoop()
        }

        NSLog("ChannelHealthMonitor: started monitoring %d adapter(s)", adapters.count)
    }

    /// Stop health monitoring.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        monitorTask?.cancel()
        monitorTask = nil
        adapterStates.removeAll()
        NSLog("ChannelHealthMonitor: stopped")
    }

    // MARK: - Status

    /// Get the current health status for a channel.
    ///
    /// - Parameter kind: The channel to check.
    /// - Returns: The current health status, or `nil` if not monitored.
    func status(for kind: ChannelKind) -> ChannelHealthStatus? {
        adapterStates[kind]?.status
    }

    /// Get all current health statuses.
    var allStatuses: [ChannelKind: ChannelHealthStatus] {
        var result: [ChannelKind: ChannelHealthStatus] = [:]
        for (kind, state) in adapterStates {
            result[kind] = state.status
        }
        return result
    }

    /// Report that an adapter has encountered an error.
    ///
    /// This is called by the gateway when an adapter operation fails.
    /// The monitor will schedule reconnection attempts.
    ///
    /// - Parameters:
    ///   - kind: The channel that failed.
    ///   - error: The error that occurred.
    func reportError(kind: ChannelKind, error: String) {
        guard var state = adapterStates[kind] else { return }
        state.status = .error(error)
        state.lastCheck = Date()
        adapterStates[kind] = state

        eventBus.send(.runtimeProgress(
            stage: "channel.health.\(kind.rawValue)",
            progress: 0.0
        ))

        NSLog("ChannelHealthMonitor: %@ reported error — %@", kind.displayName, error)
    }

    /// Report that an adapter has successfully reconnected.
    ///
    /// - Parameter kind: The channel that reconnected.
    func reportConnected(kind: ChannelKind) {
        guard var state = adapterStates[kind] else { return }
        state.status = .connected
        state.reconnectAttempts = 0
        state.lastCheck = Date()
        adapterStates[kind] = state

        eventBus.send(.runtimeProgress(
            stage: "channel.health.\(kind.rawValue)",
            progress: 1.0
        ))

        NSLog("ChannelHealthMonitor: %@ connected", kind.displayName)
    }

    /// Report that an adapter has disconnected.
    ///
    /// - Parameter kind: The channel that disconnected.
    func reportDisconnected(kind: ChannelKind) {
        guard var state = adapterStates[kind] else { return }
        state.status = .disconnected
        state.lastCheck = Date()
        adapterStates[kind] = state

        NSLog("ChannelHealthMonitor: %@ disconnected", kind.displayName)
    }

    // MARK: - Reconnection

    /// Attempt to reconnect a specific adapter.
    ///
    /// Uses exponential backoff with jitter. Returns `true` if reconnection
    /// succeeded, `false` if it failed or max attempts reached.
    ///
    /// - Parameter kind: The channel to reconnect.
    /// - Returns: Whether the reconnection was successful.
    @discardableResult
    func attemptReconnect(kind: ChannelKind) async -> Bool {
        guard var state = adapterStates[kind] else { return false }

        guard state.reconnectAttempts < config.maxReconnectAttempts else {
            state.status = .error(
                "Max reconnect attempts (\(config.maxReconnectAttempts)) exceeded"
            )
            adapterStates[kind] = state
            NSLog("ChannelHealthMonitor: %@ max reconnect attempts exceeded", kind.displayName)
            return false
        }

        state.reconnectAttempts += 1
        state.status = .reconnecting(attempt: state.reconnectAttempts)
        adapterStates[kind] = state

        NSLog("ChannelHealthMonitor: reconnecting %@ (attempt %d/%d)",
              kind.displayName, state.reconnectAttempts, config.maxReconnectAttempts)

        // Calculate exponential backoff delay.
        let delay = min(
            config.baseRetryDelay * pow(2.0, Double(state.reconnectAttempts - 1)),
            config.maxRetryDelay
        )
        // Add jitter (0-25% of delay).
        let jitter = delay * Double.random(in: 0.0...0.25)
        let totalDelay = delay + jitter

        do {
            try await Task.sleep(nanoseconds: UInt64(totalDelay * 1_000_000_000))
        } catch {
            return false
        }

        // Attempt restart.
        do {
            await state.adapter.stop()
            try await state.adapter.start()

            state.status = .connected
            state.reconnectAttempts = 0
            state.lastCheck = Date()
            adapterStates[kind] = state

            eventBus.send(.runtimeProgress(
                stage: "channel.health.\(kind.rawValue)",
                progress: 1.0
            ))

            NSLog("ChannelHealthMonitor: %@ reconnected successfully", kind.displayName)
            return true
        } catch {
            state.status = .error(error.localizedDescription)
            state.lastCheck = Date()
            adapterStates[kind] = state

            NSLog("ChannelHealthMonitor: %@ reconnect failed — %@",
                  kind.displayName, error.localizedDescription)
            return false
        }
    }

    // MARK: - Private

    /// Internal state for tracking adapter health.
    private struct AdapterHealthState {
        let adapter: any ChannelAdapter
        var status: ChannelHealthStatus
        var reconnectAttempts: Int
        var lastCheck: Date
    }

    /// The main monitoring loop.
    private func monitorLoop() async {
        while isRunning, !Task.isCancelled {
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(config.checkIntervalSeconds * 1_000_000_000)
                )
            } catch {
                break
            }

            guard isRunning else { break }

            // Check each adapter and attempt reconnection for failed ones.
            for (kind, state) in adapterStates {
                switch state.status {
                case .connected:
                    // Healthy — no action needed.
                    break

                case .disconnected, .error:
                    // Attempt reconnection if under the limit.
                    if state.reconnectAttempts < config.maxReconnectAttempts {
                        await attemptReconnect(kind: kind)
                    }

                case .reconnecting:
                    // Already reconnecting — skip.
                    break
                }
            }
        }
    }
}
