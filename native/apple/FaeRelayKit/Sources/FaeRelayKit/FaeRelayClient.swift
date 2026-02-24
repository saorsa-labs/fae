import Foundation
import MultipeerConnectivity
import Combine
import FaeOrbKit

/// Discovers and connects to a Mac running Fae via Multipeer Connectivity.
///
/// Provides an `@Observable`-friendly interface for SwiftUI binding.
/// Handles discovery, connection lifecycle, JSON message exchange,
/// and binary audio frame relay.
@MainActor
public final class FaeRelayClient: NSObject, ObservableObject {

    // MARK: - Published State

    @Published public private(set) var connectionState: ConnectionState = .disconnected
    @Published public private(set) var macDisplayName: String?
    @Published public private(set) var orbMode: OrbMode = .idle
    @Published public private(set) var orbFeeling: OrbFeeling = .neutral
    @Published public private(set) var orbPalette: OrbPalette = .modeDefault
    @Published public private(set) var lastAssistantText: String?
    @Published public private(set) var lastUserText: String?
    @Published public private(set) var audioRMS: Float = 0
    @Published public private(set) var pipelineState: String = "unknown"

    public enum ConnectionState: String, Sendable {
        case disconnected
        case searching
        case connecting
        case connected
    }

    // MARK: - Callbacks

    /// Called when TTS audio frames arrive from the Mac.
    public var onTTSAudio: ((Data, AudioFrameHeader) -> Void)?

    /// Called when conversation turns arrive.
    public var onConversationTurn: ((String, String, Bool) -> Void)?  // role, content, isFinal

    // MARK: - Multipeer Connectivity

    private let peerID: MCPeerID
    private var session: MCSession?
    private var browser: MCNearbyServiceBrowser?

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: - Init

    public override init() {
        #if os(iOS)
        self.peerID = MCPeerID(displayName: UIDevice.current.name)
        #elseif os(macOS)
        self.peerID = MCPeerID(displayName: Host.current().localizedName ?? "Mac")
        #else
        self.peerID = MCPeerID(displayName: "Fae Companion")
        #endif
        super.init()
    }

    // MARK: - Connection Lifecycle

    /// Begin searching for a Mac running Fae on the local network.
    public func startSearching() {
        guard connectionState == .disconnected else { return }

        let session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        self.session = session

        let browser = MCNearbyServiceBrowser(peer: peerID, serviceType: FaeRelayConstants.serviceType)
        browser.delegate = self
        self.browser = browser
        browser.startBrowsingForPeers()

        connectionState = .searching
    }

    /// Stop searching and disconnect.
    public func disconnect() {
        browser?.stopBrowsingForPeers()
        browser = nil
        session?.disconnect()
        session = nil
        connectionState = .disconnected
        macDisplayName = nil
    }

    // MARK: - Send Commands

    /// Send a command to the Mac brain.
    public func sendCommand(_ command: String, payload: [String: AnyCodable] = [:]) {
        guard let session, let peer = session.connectedPeers.first else { return }
        let envelope = CommandEnvelope(command: command, payload: payload)
        guard let data = try? encoder.encode(envelope) else { return }
        try? session.send(data, toPeers: [peer], with: .reliable)
    }

    /// Send raw audio data (mic capture) to the Mac.
    public func sendMicAudio(_ pcmData: Data, flags: UInt8 = 0) {
        guard let session, let peer = session.connectedPeers.first else { return }
        let header = AudioFrameHeader(
            frameType: AudioFrameHeader.micAudio,
            flags: flags,
            payloadLength: UInt16(min(pcmData.count, Int(UInt16.max)))
        )
        var frame = header.encode()
        frame.append(pcmData)
        try? session.send(frame, toPeers: [peer], with: .unreliable)
    }

    /// Send "go home" command to transfer session back to Mac.
    public func goHome() {
        sendCommand("device.go_home")
    }

    // MARK: - Message Handling

    nonisolated private func handleReceivedData(_ data: Data) {
        // Check if it's a binary audio frame (starts with known frame type byte).
        if data.count >= 4 {
            let frameType = data[0]
            if frameType == AudioFrameHeader.ttsAudio || frameType == AudioFrameHeader.audioLevel {
                if let header = AudioFrameHeader.decode(from: data) {
                    let audioPayload = data.dropFirst(4)
                    Task { @MainActor in
                        if frameType == AudioFrameHeader.audioLevel, audioPayload.count >= 4 {
                            self.audioRMS = audioPayload.withUnsafeBytes { $0.load(as: Float.self) }
                        } else {
                            self.onTTSAudio?(Data(audioPayload), header)
                        }
                    }
                }
                return
            }
        }

        // Otherwise treat as JSON.
        guard let event = try? JSONDecoder().decode(EventEnvelope.self, from: data) else { return }

        Task { @MainActor in
            self.handleEvent(event)
        }
    }

    private func handleEvent(_ event: EventEnvelope) {
        switch event.event {
        case "orb.state":
            if let orbState = OrbStateEvent(from: event.payload) {
                orbMode = orbState.mode
                orbFeeling = orbState.feeling
                orbPalette = orbState.palette
            }

        case "conversation.turn":
            if let role = event.payload["role"]?.stringValue,
               let content = event.payload["content"]?.stringValue {
                let isFinal = event.payload["final"]?.boolValue ?? false
                if role == "assistant" {
                    lastAssistantText = content
                } else if role == "user" {
                    lastUserText = content
                }
                onConversationTurn?(role, content, isFinal)
            }

        case "pipeline.state":
            if let state = event.payload["state"]?.stringValue {
                pipelineState = state
            }

        case "runtime.assistant_sentence":
            if let text = event.payload["text"]?.stringValue {
                lastAssistantText = text
            }

        default:
            break
        }
    }
}

// MARK: - MCSessionDelegate

extension FaeRelayClient: MCSessionDelegate {
    nonisolated public func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            switch state {
            case .connecting:
                self.connectionState = .connecting
            case .connected:
                self.connectionState = .connected
                self.macDisplayName = peerID.displayName
                // Request initial state
                self.sendCommand("runtime.status")
            case .notConnected:
                if self.connectionState == .connected {
                    // Lost connection — restart search
                    self.connectionState = .searching
                    self.macDisplayName = nil
                    self.browser?.startBrowsingForPeers()
                }
            @unknown default:
                break
            }
        }
    }

    nonisolated public func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        handleReceivedData(data)
    }

    nonisolated public func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated public func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated public func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

// MARK: - MCNearbyServiceBrowserDelegate

extension FaeRelayClient: MCNearbyServiceBrowserDelegate {
    nonisolated public func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        // Auto-invite discovered Mac peers.
        Task { @MainActor in
            guard let session = self.session else { return }
            browser.invitePeer(peerID, to: session, withContext: nil, timeout: 30)
            self.connectionState = .connecting
        }
    }

    nonisolated public func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        // Peer will be rediscovered if it comes back.
    }
}
