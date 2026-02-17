import AVFoundation
import AVKit
import SwiftUI

struct AudioInputDevice: Identifiable, Hashable {
    let id: String
    let name: String
}

@MainActor
final class AudioDeviceController: ObservableObject {
    @Published private(set) var inputDevices: [AudioInputDevice] = []
    @Published var selectedInputID: String = ""
    @Published private(set) var microphoneAccessGranted = false

    init() {
        refreshMicrophoneAccessAndDevices()
    }

    func refreshMicrophoneAccessAndDevices() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphoneAccessGranted = true
            refreshInputDevices()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    self.microphoneAccessGranted = granted
                    self.refreshInputDevices()
                }
            }
        case .denied, .restricted:
            microphoneAccessGranted = false
            inputDevices = []
            selectedInputID = ""
        @unknown default:
            microphoneAccessGranted = false
            inputDevices = []
            selectedInputID = ""
        }
    }

    func refreshInputDevices() {
        guard microphoneAccessGranted else {
            inputDevices = []
            selectedInputID = ""
            return
        }

        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )

        let devices = session.devices.map {
            AudioInputDevice(id: $0.uniqueID, name: $0.localizedName)
        }
        self.inputDevices = devices

        if selectedInputID.isEmpty {
            selectedInputID = devices.first?.id ?? ""
        }

        if !devices.contains(where: { $0.id == selectedInputID }) {
            selectedInputID = devices.first?.id ?? ""
        }
    }

    var selectedInputName: String {
        inputDevices.first(where: { $0.id == selectedInputID })?.name ?? "System Default"
    }
}

struct AudioRoutePicker: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        AVRoutePickerView(frame: .zero)
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {
        _ = context
        _ = nsView
    }
}
