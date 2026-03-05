import Foundation

/// Persists user-granted tool approvals ("Always", "Allow All Read-Only", "Allow All In Current Mode").
///
/// Storage: `~/Library/Application Support/fae/approved_tools.json`
///
/// Thread-safe via actor isolation. All mutations are persisted immediately.
actor ApprovedToolsStore {

    struct ApprovalSnapshot: Sendable {
        let approvedTools: [String]
        let approveAllReadonly: Bool
        let approveAll: Bool
    }

    /// Singleton shared instance.
    static let shared = ApprovedToolsStore()

    // MARK: - Schema

    struct ApprovedTool: Codable, Sendable {
        let approvedAt: String
    }

    struct StoreData: Codable, Sendable {
        var version: Int = 1
        var tools: [String: ApprovedTool] = [:]
        var approveAllReadonly: Bool = false
        var approveAll: Bool = false

        enum CodingKeys: String, CodingKey {
            case version
            case tools
            case approveAllReadonly = "approve_all_readonly"
            case approveAll = "approve_all"
        }
    }

    // MARK: - State

    private var data: StoreData

    private static var storeURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("fae/approved_tools.json")
    }

    // MARK: - Init

    private init() {
        data = Self.loadFromDisk()
    }

    // MARK: - Queries

    /// Check whether a specific tool has been individually approved ("Always").
    func isToolApproved(_ toolName: String) -> Bool {
        data.tools[toolName] != nil
    }

    /// Check whether "Allow All Read-Only" is enabled.
    func isApproveAllReadonly() -> Bool {
        data.approveAllReadonly
    }

    /// Check whether "Allow All In Current Mode" is enabled.
    func isApproveAll() -> Bool {
        data.approveAll
    }

    /// Returns true if the tool should be auto-approved based on stored grants.
    ///
    /// Evaluation order:
    /// 1. `approve_all == true` → approve everything
    /// 2. `approve_all_readonly == true` and risk is `.low` → approve
    /// 3. Tool name individually approved → approve
    /// 4. None match → not approved
    func shouldAutoApprove(toolName: String, riskLevel: ToolRiskLevel) -> Bool {
        if data.approveAll { return true }
        if data.approveAllReadonly && riskLevel == .low { return true }
        if data.tools[toolName] != nil { return true }
        return false
    }

    /// All individually approved tool names.
    func approvedToolNames() -> [String] {
        Array(data.tools.keys).sorted()
    }

    func approvalSnapshot() -> ApprovalSnapshot {
        ApprovalSnapshot(
            approvedTools: approvedToolNames(),
            approveAllReadonly: data.approveAllReadonly,
            approveAll: data.approveAll
        )
    }

    // MARK: - Mutations

    /// Approve a specific tool forever ("Always").
    func approveTool(_ toolName: String) {
        let now = ISO8601DateFormatter().string(from: Date())
        data.tools[toolName] = ApprovedTool(approvedAt: now)
        persist()
    }

    /// Enable "Allow All Read-Only" (all low-risk tools auto-approved).
    func setApproveAllReadonly(_ enabled: Bool) {
        data.approveAllReadonly = enabled
        persist()
    }

    /// Enable "Allow All In Current Mode" (all tools auto-approved within current mode gates).
    func setApproveAll(_ enabled: Bool) {
        data.approveAll = enabled
        persist()
    }

    /// Revoke a specific tool's "Always" approval.
    func revokeTool(_ toolName: String) {
        data.tools.removeValue(forKey: toolName)
        persist()
    }

    /// Revoke all approvals — returns to default (confirm everything).
    func revokeAll() {
        data.tools.removeAll()
        data.approveAllReadonly = false
        data.approveAll = false
        persist()
    }

    // MARK: - Persistence

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let jsonData = try? encoder.encode(data) else { return }

        let url = Self.storeURL
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? jsonData.write(to: url, options: .atomic)
    }

    private static func loadFromDisk() -> StoreData {
        guard let jsonData = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode(StoreData.self, from: jsonData)
        else {
            return StoreData()
        }
        return decoded
    }

    /// Reload from disk (used after external edits, e.g., Settings revocation).
    func reload() {
        data = Self.loadFromDisk()
    }
}
