import SwiftUI

/// Full-screen license acceptance gate shown on first launch.
///
/// The user must scroll through and accept the AGPL-3.0 license before
/// Fae starts. The acceptance is persisted in `config.toml` so it only
/// shows once.
struct LicenseAcceptanceView: View {
    let onAccept: () -> Void
    let onDecline: () -> Void

    @State private var hasScrolledToBottom = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                Text("License Agreement")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text("Please read and accept before using Fae")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 24)
            .padding(.bottom, 16)

            // License text in a scrollable area
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(Self.licenseNotice)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.white.opacity(0.85))
                            .textSelection(.enabled)

                        // Invisible anchor at the bottom to detect scroll completion
                        Color.clear
                            .frame(height: 1)
                            .id("license-bottom")
                            .onAppear {
                                hasScrolledToBottom = true
                            }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }
                .background(Color.black.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 20)
            }

            // Buttons
            VStack(spacing: 12) {
                Button(action: onAccept) {
                    Text("I Accept")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(.accentColor)
                .disabled(!hasScrolledToBottom)
                .help(
                    hasScrolledToBottom
                        ? "Accept the AGPL-3.0 license and start using Fae"
                        : "Please scroll to the bottom of the license to continue"
                )

                Button(action: onDecline) {
                    Text("Decline")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                if !hasScrolledToBottom {
                    Text("Scroll to the bottom of the license to enable acceptance")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .preferredColorScheme(.dark)
    }

    // MARK: - License Text

    /// Summarised AGPL-3.0 notice with warranty disclaimer.
    ///
    /// We show a human-readable summary with the key warranty/liability
    /// disclaimers, plus a reference to the full license file.
    static let licenseNotice: String = """
    FAE — Personal AI Companion
    Copyright (C) 2024-2026 Saorsa Labs

    This program is free software: you can redistribute it \
    and/or modify it under the terms of the GNU Affero General \
    Public License as published by the Free Software Foundation, \
    either version 3 of the License, or (at your option) any \
    later version.

    This program is distributed in the hope that it will be \
    useful, but WITHOUT ANY WARRANTY; without even the implied \
    warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR \
    PURPOSE. See the GNU Affero General Public License for more \
    details.

    You should have received a copy of the GNU Affero General \
    Public License along with this program. If not, see \
    <https://www.gnu.org/licenses/>.

    ─────────────────────────────────────────────

    IMPORTANT NOTICES

    1. NO WARRANTY
       This software is provided "as is", without warranty of \
    any kind, express or implied. The entire risk as to the \
    quality and performance of the program is with you. Should \
    the program prove defective, you assume the cost of all \
    necessary servicing, repair or correction.

    2. LIMITATION OF LIABILITY
       In no event unless required by applicable law or agreed \
    to in writing will any copyright holder, or any other party \
    who modifies and/or conveys the program, be liable to you \
    for damages, including any general, special, incidental or \
    consequential damages arising out of the use or inability \
    to use the program.

    3. LOCAL PROCESSING
       Fae runs entirely on your device. All speech recognition, \
    language model inference, and text-to-speech synthesis happen \
    locally. No audio or conversation data is sent to external \
    servers. However, Fae downloads ML model weights from \
    HuggingFace Hub on first launch, and optional features \
    (web search, auto-updates) may make network requests when \
    you use them.

    4. OPEN SOURCE
       The complete source code for Fae is available under the \
    AGPL-3.0 license at:
       https://github.com/saorsa-labs/fae

    5. AI LIMITATIONS
       Fae is an AI assistant powered by local language models. \
    Her responses may be inaccurate, incomplete, or inappropriate. \
    Do not rely on Fae for medical, legal, financial, or safety-\
    critical decisions. Always verify important information \
    independently.

    ─────────────────────────────────────────────

    By clicking "I Accept", you acknowledge that you have read \
    and agree to the terms of the GNU Affero General Public \
    License v3.0, and you understand the disclaimers above.
    """
}
