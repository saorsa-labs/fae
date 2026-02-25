import Foundation
import MultipeerConnectivity
import Combine

/// Advertises this Mac on the local network via Multipeer Connectivity so that
/// companion devices (iPhone, iPad, Watch) can discover and connect.
///
/// Once connected, the relay server:
/// - Pushes orb state, conversation turns, and pipeline events to companions
/// - Receives commands from companions and routes them to the Rust backend
/// - Relays binary audio frames (TTS → companion, mic → backend)
///
/// ## Integration
///
/// Instantiated as a `@StateObject` in `FaeApp` and started in `.onAppear`.
/// Subscribes to `OrbStateController`, `ConversationController`, and
/// `PipelineAuxBridgeController` to broadcast state changes.
@MainActor
final class FaeRelayServer: NSObject, ObservableObject {

    // MARK: - Published State

    @Published private(set) var connectedCompanions: [MCPeerID] = []
    @Published private(set) var isAdvertising = false

    // MARK: - Service Constants

    private static let serviceType = "fae-relay"
    private static let protocolVersion: UInt32 = 1

    // MARK: - Multipeer Connectivity

    private let peerID: MCPeerID
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?

    // MARK: - Dependencies

    weak var orbState: OrbStateController?
    weak var commandSender: HostCommandSender?
    /// Direct reference for binary audio injection (bypasses JSON command path).
    weak var audioSender: EmbeddedCoreSender?

    // MARK: - Internal State

    private var cancellables = Set<AnyCancellable>()
    private let encoder = JSONEncoder()
    private var eventCounter: UInt64 = 0
    /// Tracks the last broadcast orb state to avoid redundant sends.
    private var lastBroadcastMode: OrbMode?
    private var lastBroadcastFeeling: OrbFeeling?
    private var lastBroadcastPalette: OrbPalette?

    // MARK: - Notification Observers

    private var notificationObservers: [NSObjectProtocol] = []

    // MARK: - Init

    override init() {
        self.peerID = MCPeerID(displayName: Host.current().localizedName ?? "Fae Mac")
        super.init()
    }

    deinit {
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Lifecycle

    /// Begin advertising this Mac and accepting companion connections.
    func start() {
        guard !isAdvertising else { return }

        let session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        self.session = session

        let advertiser = MCNearbyServiceAdvertiser(
            peer: peerID,
            discoveryInfo: ["version": "1"],
            serviceType: Self.serviceType
        )
        advertiser.delegate = self
        self.advertiser = advertiser
        advertiser.startAdvertisingPeer()

        isAdvertising = true
        NSLog("FaeRelayServer: started advertising as '%@'", peerID.displayName)

        subscribeToNotifications()
    }

    /// Stop advertising and disconnect all companions.
    func stop() {
        advertiser?.stopAdvertisingPeer()
        advertiser = nil
        session?.disconnect()
        session = nil
        connectedCompanions = []
        isAdvertising = false
        cancellables.removeAll()
    }

    // MARK: - Orb State Binding

    /// Subscribe to orb state changes to push updates to connected companions.
    func bindOrbState(_ orbState: OrbStateController) {
        self.orbState = orbState

        orbState.$mode
            .combineLatest(orbState.$palette, orbState.$feeling)
            .sink { [weak self] mode, palette, feeling in
                guard let self else { return }
                // Skip if unchanged.
                guard mode != self.lastBroadcastMode
                    || feeling != self.lastBroadcastFeeling
                    || palette != self.lastBroadcastPalette
                else { return }
                self.lastBroadcastMode = mode
                self.lastBroadcastFeeling = feeling
                self.lastBroadcastPalette = palette
                self.broadcastOrbState(mode: mode, palette: palette, feeling: feeling)
            }
            .store(in: &cancellables)
    }

    // MARK: - Notification Subscriptions

    /// Subscribe to backend notifications to relay events to companions.
    private func subscribeToNotifications() {
        let center = NotificationCenter.default

        // Conversation turns (assistant sentences, user transcripts).
        notificationObservers.append(
            center.addObserver(
                forName: .faeAssistantMessage,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let text = notification.userInfo?["text"] as? String else { return }
                Task { @MainActor in
                    self?.broadcastEvent("conversation.turn", payload: [
                        "role": "assistant",
                        "content": text,
                        "final": false,
                    ])
                }
            }
        )

        notificationObservers.append(
            center.addObserver(
                forName: .faeTranscription,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let text = notification.userInfo?["text"] as? String else { return }
                Task { @MainActor in
                    self?.broadcastEvent("conversation.turn", payload: [
                        "role": "user",
                        "content": text,
                        "final": true,
                    ])
                }
            }
        )

        // Pipeline state changes.
        notificationObservers.append(
            center.addObserver(
                forName: .faePipelineState,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let state = notification.userInfo?["state"] as? String else { return }
                Task { @MainActor in
                    self?.broadcastEvent("pipeline.state", payload: [
                        "state": state,
                    ])
                }
            }
        )

        // Audio level (RMS) for companion orb animation.
        notificationObservers.append(
            center.addObserver(
                forName: .faeAudioLevel,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let rms = notification.userInfo?["rms"] as? Float else { return }
                Task { @MainActor in
                    self?.broadcastAudioLevel(rms)
                }
            }
        )
    }

    // MARK: - Broadcasting

    /// Send an orb state event to all connected companions.
    private func broadcastOrbState(mode: OrbMode, palette: OrbPalette, feeling: OrbFeeling) {
        broadcastEvent("orb.state", payload: [
            "mode": mode.rawValue,
            "palette": palette.rawValue,
            "feeling": feeling.rawValue,
        ])
    }

    /// Send a JSON event envelope to all connected companions.
    private func broadcastEvent(_ event: String, payload: [String: Any]) {
        guard let session, !session.connectedPeers.isEmpty else { return }

        eventCounter += 1
        let envelope: [String: Any] = [
            "v": Self.protocolVersion,
            "event_id": "ev-\(eventCounter)",
            "event": event,
            "payload": payload,
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: envelope) else { return }
        try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
    }

    /// Send a binary audio level frame to all connected companions.
    private func broadcastAudioLevel(_ rms: Float) {
        guard let session, !session.connectedPeers.isEmpty else { return }

        // Audio level frame: type=0x03, flags=0, length=4, then Float32.
        var data = Data(capacity: 8)
        data.append(0x03) // audioLevel frame type
        data.append(0x00) // flags
        var payloadLen = UInt16(4).bigEndian
        data.append(Data(bytes: &payloadLen, count: 2))
        var rmsValue = rms
        data.append(Data(bytes: &rmsValue, count: 4))

        try? session.send(data, toPeers: session.connectedPeers, with: .unreliable)
    }

    // MARK: - Command Handling

    /// Handle a command received from a companion device.
    nonisolated private func handleReceivedData(_ data: Data, from peer: MCPeerID) {
        // Check for binary audio frames (mic audio from companion).
        if data.count >= 4 {
            let frameType = data[0]
            if frameType == 0x01 { // micAudio
                // Parse header: [type(1)] [flags(1)] [length_hi(1)] [length_lo(1)] [PCM...]
                let pcmData = data.dropFirst(4)
                guard pcmData.count >= 4 else { return }
                // Interpret raw bytes as f32 array and inject into Rust pipeline.
                let floatCount = pcmData.count / MemoryLayout<Float>.size
                let samples: [Float] = pcmData.withUnsafeBytes { raw in
                    let bound = raw.bindMemory(to: Float.self)
                    return Array(bound.prefix(floatCount))
                }
                Task { @MainActor in
                    self.audioSender?.injectAudio(samples: samples)
                }
                return
            }
        }

        // Parse JSON command envelope.
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = json["command"] as? String
        else { return }

        let requestId = json["request_id"] as? String ?? ""

        Task { @MainActor in
            self.routeCommand(command, requestId: requestId, from: peer)
        }
    }

    /// Route a command from a companion to the appropriate handler.
    private func routeCommand(_ command: String, requestId: String, from peer: MCPeerID) {
        switch command {
        case "device.go_home":
            // Companion is sending the session back to Mac.
            NotificationCenter.default.post(
                name: .faeDeviceTransfer,
                object: nil,
                userInfo: [
                    "event": "device.home_requested",
                    "payload": [:] as [String: Any],
                ]
            )
            sendResponse(requestId: requestId, ok: true, to: peer)

        case "runtime.status":
            // Companion requesting current state — send orb state.
            if let orbState {
                broadcastOrbState(
                    mode: orbState.mode,
                    palette: orbState.palette,
                    feeling: orbState.feeling
                )
            }
            sendResponse(requestId: requestId, ok: true, to: peer)

        case "conversation.inject_text":
            // Forward text injection to the Rust backend.
            commandSender?.sendCommand(name: command, payload: [:])
            sendResponse(requestId: requestId, ok: true, to: peer)

        default:
            // Forward unknown commands to the Rust backend.
            commandSender?.sendCommand(name: command, payload: [:])
            sendResponse(requestId: requestId, ok: true, to: peer)
        }
    }

    /// Send a response envelope back to a companion.
    private func sendResponse(requestId: String, ok: Bool, to peer: MCPeerID, error: String? = nil) {
        guard let session else { return }
        let envelope: [String: Any] = [
            "v": Self.protocolVersion,
            "request_id": requestId,
            "ok": ok,
            "error": error as Any,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: envelope) else { return }
        try? session.send(data, toPeers: [peer], with: .reliable)
    }
}

// MARK: - MCSessionDelegate

extension FaeRelayServer: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            switch state {
            case .connected:
                if !self.connectedCompanions.contains(peerID) {
                    self.connectedCompanions.append(peerID)
                }
                NSLog("FaeRelayServer: companion connected — %@", peerID.displayName)
                // Push current orb state to the newly connected companion.
                if let orbState = self.orbState {
                    self.broadcastOrbState(
                        mode: orbState.mode,
                        palette: orbState.palette,
                        feeling: orbState.feeling
                    )
                }
            case .notConnected:
                self.connectedCompanions.removeAll { $0 == peerID }
                NSLog("FaeRelayServer: companion disconnected — %@", peerID.displayName)
            case .connecting:
                NSLog("FaeRelayServer: companion connecting — %@", peerID.displayName)
            @unknown default:
                break
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        handleReceivedData(data, from: peerID)
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension FaeRelayServer: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        // Auto-accept invitations from companion devices.
        Task { @MainActor in
            NSLog("FaeRelayServer: accepting invitation from %@", peerID.displayName)
            invitationHandler(true, self.session)
        }
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        NSLog("FaeRelayServer: failed to start advertising — %@", error.localizedDescription)
    }
}
