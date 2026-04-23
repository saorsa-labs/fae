import SwiftUI

/// Privacy filter section: informational showcase for the on-device PII scanner
/// plus a single debug-disable toggle.
///
/// The filter runs OpenAI Privacy Filter (1.5B total / 50M active SMoE) via
/// `mlx-embeddings` in a Python subprocess. Outbound CoWork prompts are scanned
/// before they leave the Mac; detected PII emits a `cowork.pii_detected` event
/// and a security log entry. The outbound prompt itself is not mutated in this
/// release — detection and observation only.
struct SettingsPrivacyFilterTab: View {
    @AppStorage("privacy.piiFilterEnabled") private var piiFilterEnabled: Bool = true

    var body: some View {
        Form {
            Section("On-device PII Scanning") {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(FaeDesign.heatherMistText)
                        .frame(width: 26, alignment: .center)
                        .padding(.top, 2)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Outbound privacy filter")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text("Every prompt sent to CoWork's external models is first scanned on-device for personally-identifying information — names, emails, phone numbers, addresses, dates, URLs, account numbers, secrets. The filter runs locally in 1.5B-parameter sparse-MoE model; nothing leaves the Mac to run it.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("What gets flagged") {
                categoryRow(icon: "person.fill", label: "People",
                            description: "First names, full names, spoken or written.")
                categoryRow(icon: "envelope.fill", label: "Email addresses",
                            description: "Any address matching standard formats.")
                categoryRow(icon: "phone.fill", label: "Phone numbers",
                            description: "Domestic and international formats.")
                categoryRow(icon: "mappin.circle.fill", label: "Physical addresses",
                            description: "Street addresses, apartment numbers, landmarks.")
                categoryRow(icon: "calendar", label: "Dates",
                            description: "Birthdays, appointments, any explicit date.")
                categoryRow(icon: "link", label: "URLs",
                            description: "Private links, invite URLs, tokens in paths.")
                categoryRow(icon: "creditcard.fill", label: "Account numbers",
                            description: "Bank, card, SSN-format strings.")
                categoryRow(icon: "key.fill", label: "Secrets",
                            description: "API keys, tokens, passwords, credentials.")
            }

            Section("How this release behaves") {
                bulletRow("Detect-only",
                          "Flagged content is logged and surfaces in the UI; the outbound prompt is not yet mutated.")
                bulletRow("Fail-open",
                          "If the scanner can't run (first install, offline, resource pressure), CoWork continues without it.")
                bulletRow("On-device",
                          "The scanner model runs locally via MLX. No text is sent anywhere to perform the scan.")
                bulletRow("Future releases",
                          "Automatic substitution of detected PII with category placeholders, gated behind a second toggle.")
            }

            Section("Advanced") {
                Toggle("Run privacy filter", isOn: $piiFilterEnabled)
                    .toggleStyle(.switch)
                Text("Off disables PII scanning entirely. Leave on unless you are debugging the scanner.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func categoryRow(icon: String, label: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(FaeDesign.heatherMistText)
                .frame(width: 22, alignment: .center)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(description)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func bulletRow(_ title: String, _ description: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "circle.fill")
                .font(.system(size: 5))
                .foregroundStyle(.secondary)
                .padding(.top, 7)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(description)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
