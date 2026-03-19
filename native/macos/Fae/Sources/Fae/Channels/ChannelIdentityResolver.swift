import Foundation

// MARK: - CanonicalIdentity

/// A canonical identity that links a person across multiple channel platforms.
///
/// When the same person messages via both WhatsApp and iMessage (using the same
/// phone number, for example), `ChannelIdentityResolver` links their platform
/// IDs to a single `CanonicalIdentity`. This allows session context to be shared.
struct CanonicalIdentity: Sendable, Equatable, Hashable {
    /// Unique identifier for this canonical identity.
    let id: String

    /// Human-readable display name (best-effort, from any linked platform).
    let displayName: String?

    /// All platform identities linked to this canonical identity.
    let platformIds: [PlatformIdentity]

    /// Optional entity ID linking this identity to the `EntityStore` persons graph.
    let entityId: String?
}

// MARK: - PlatformIdentity

/// A sender identity on a specific channel platform.
struct PlatformIdentity: Sendable, Equatable, Hashable {
    /// The channel this identity belongs to.
    let channel: ChannelKind

    /// Platform-specific sender ID (phone number, Discord user ID, etc.).
    let senderId: String
}

// MARK: - IdentityLink

/// A stored link between a platform identity and a canonical identity.
struct IdentityLink: Sendable {
    /// The platform identity.
    let platformId: PlatformIdentity

    /// The canonical identity ID this platform identity is linked to.
    let canonicalId: String

    /// How this link was established.
    let linkSource: LinkSource

    /// When this link was created.
    let createdAt: Date
}

/// How an identity link was established.
enum LinkSource: String, Sendable {
    /// Phone number normalisation matched across platforms.
    case phoneMatch
    /// Display name matched across platforms.
    case displayNameMatch
    /// Explicitly linked by the user or an LLM tool call.
    case manual
    /// Linked via EntityStore entity matching.
    case entityMatch
}

// MARK: - ChannelIdentityResolver

/// Resolves platform sender identities to canonical cross-channel identities.
///
/// The resolver maintains an in-memory mapping of platform IDs to canonical
/// identities. It supports automatic linking via phone number normalisation
/// and display name matching, as well as manual linking.
///
/// Thread safety is provided by the actor model.
actor ChannelIdentityResolver {
    /// All known identity links, keyed by platform identity.
    private var links: [PlatformIdentity: IdentityLink] = [:]

    /// Canonical identities keyed by their ID.
    private var identities: [String: CanonicalIdentity] = [:]

    /// Reverse index: canonical ID → set of platform identities.
    private var reverseIndex: [String: Set<PlatformIdentity>] = [:]

    // MARK: - Resolution

    /// Resolve a platform sender to a canonical identity, if one exists.
    ///
    /// - Parameters:
    ///   - channel: The channel the sender messaged from.
    ///   - senderId: The platform-specific sender ID.
    /// - Returns: The canonical identity, or `nil` if the sender is unknown.
    func resolve(channel: ChannelKind, senderId: String) -> CanonicalIdentity? {
        let platformId = PlatformIdentity(channel: channel, senderId: senderId)
        guard let link = links[platformId] else { return nil }
        return identities[link.canonicalId]
    }

    /// Find all linked sessions for a given platform identity.
    ///
    /// Returns the `SessionKey`s for every platform identity linked to the same
    /// canonical identity, excluding the queried one.
    ///
    /// - Parameters:
    ///   - channel: The channel the sender messaged from.
    ///   - senderId: The platform-specific sender ID.
    /// - Returns: Session keys for linked identities on other channels.
    func linkedSessionKeys(channel: ChannelKind, senderId: String) -> [SessionKey] {
        let platformId = PlatformIdentity(channel: channel, senderId: senderId)
        guard let link = links[platformId],
              let siblings = reverseIndex[link.canonicalId]
        else { return [] }

        return siblings
            .filter { $0 != platformId }
            .map { SessionKey(channel: $0.channel, senderId: $0.senderId) }
    }

    // MARK: - Linking

    /// Link a platform identity to a canonical identity (or create one).
    ///
    /// If the platform identity is already linked, this is a no-op.
    /// If `canonicalId` is provided and exists, the platform ID is added to it.
    /// Otherwise, a new canonical identity is created.
    ///
    /// - Parameters:
    ///   - channel: The channel this identity belongs to.
    ///   - senderId: The platform-specific sender ID.
    ///   - displayName: Optional display name for the identity.
    ///   - canonicalId: Optional existing canonical identity to link to.
    ///   - entityId: Optional entity store ID for person graph linking.
    ///   - source: How this link was established.
    /// - Returns: The canonical identity the platform ID is now linked to.
    @discardableResult
    func link(
        channel: ChannelKind,
        senderId: String,
        displayName: String? = nil,
        canonicalId: String? = nil,
        entityId: String? = nil,
        source: LinkSource = .manual
    ) -> CanonicalIdentity {
        let platformId = PlatformIdentity(channel: channel, senderId: senderId)

        // Already linked — return existing.
        if let existingLink = links[platformId],
           let existingIdentity = identities[existingLink.canonicalId]
        {
            return existingIdentity
        }

        // Find or create the canonical identity.
        let resolvedCanonicalId: String
        if let canonicalId, identities[canonicalId] != nil {
            resolvedCanonicalId = canonicalId
        } else {
            resolvedCanonicalId = newCanonicalId()
        }

        // Create the link.
        let link = IdentityLink(
            platformId: platformId,
            canonicalId: resolvedCanonicalId,
            linkSource: source,
            createdAt: Date()
        )
        links[platformId] = link

        // Update reverse index.
        var siblings = reverseIndex[resolvedCanonicalId] ?? []
        siblings.insert(platformId)
        reverseIndex[resolvedCanonicalId] = siblings

        // Rebuild the canonical identity with all current platform IDs.
        let allPlatformIds = Array(siblings)
        let bestDisplayName = displayName ?? identities[resolvedCanonicalId]?.displayName
        let bestEntityId = entityId ?? identities[resolvedCanonicalId]?.entityId

        let identity = CanonicalIdentity(
            id: resolvedCanonicalId,
            displayName: bestDisplayName,
            platformIds: allPlatformIds,
            entityId: bestEntityId
        )
        identities[resolvedCanonicalId] = identity

        NSLog("ChannelIdentityResolver: linked %@:%@ → canonical %@ (source: %@)",
              channel.rawValue, senderId, resolvedCanonicalId, source.rawValue)

        return identity
    }

    /// Unlink a platform identity from its canonical identity.
    ///
    /// - Parameters:
    ///   - channel: The channel to unlink.
    ///   - senderId: The platform-specific sender ID.
    /// - Returns: `true` if the link existed and was removed.
    @discardableResult
    func unlink(channel: ChannelKind, senderId: String) -> Bool {
        let platformId = PlatformIdentity(channel: channel, senderId: senderId)
        guard let link = links.removeValue(forKey: platformId) else { return false }

        // Update reverse index.
        reverseIndex[link.canonicalId]?.remove(platformId)

        // If the canonical identity has no more platform IDs, remove it.
        if let remaining = reverseIndex[link.canonicalId], remaining.isEmpty {
            reverseIndex.removeValue(forKey: link.canonicalId)
            identities.removeValue(forKey: link.canonicalId)
        } else {
            // Rebuild canonical identity without this platform ID.
            rebuildCanonicalIdentity(link.canonicalId)
        }

        return true
    }

    // MARK: - Auto-Linking

    /// Attempt to auto-link a sender by matching their phone number across channels.
    ///
    /// Phone numbers are normalised by stripping non-digit characters and comparing
    /// suffixes (last 10 digits). This handles international prefix differences.
    ///
    /// - Parameters:
    ///   - channel: The channel the sender messaged from.
    ///   - senderId: The sender's platform ID (e.g. phone number).
    ///   - displayName: Optional display name.
    /// - Returns: The canonical identity if a match was found and linked, or `nil`.
    func autoLinkByPhone(
        channel: ChannelKind,
        senderId: String,
        displayName: String? = nil
    ) -> CanonicalIdentity? {
        let normalised = normalisePhoneNumber(senderId)
        guard normalised.count >= 7 else { return nil }

        // Search existing links for a matching phone number on a different channel.
        for (existingPlatformId, existingLink) in links {
            guard existingPlatformId.channel != channel else { continue }

            let existingNormalised = normalisePhoneNumber(existingPlatformId.senderId)
            guard phoneNumbersMatch(normalised, existingNormalised) else { continue }

            // Found a match — link to the same canonical identity.
            return link(
                channel: channel,
                senderId: senderId,
                displayName: displayName,
                canonicalId: existingLink.canonicalId,
                source: .phoneMatch
            )
        }

        return nil
    }

    /// Attempt to auto-link a sender by matching their display name across channels.
    ///
    /// Display names are compared case-insensitively after trimming whitespace.
    /// Only exact matches are linked (fuzzy matching is intentionally avoided to
    /// prevent false positives).
    ///
    /// - Parameters:
    ///   - channel: The channel the sender messaged from.
    ///   - senderId: The sender's platform ID.
    ///   - displayName: The sender's display name.
    /// - Returns: The canonical identity if a match was found, or `nil`.
    func autoLinkByDisplayName(
        channel: ChannelKind,
        senderId: String,
        displayName: String
    ) -> CanonicalIdentity? {
        let normalisedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalisedName.isEmpty else { return nil }

        // Search canonical identities for a matching display name.
        for (canonicalId, identity) in identities {
            guard let existingName = identity.displayName else { continue }
            let existingNormalised = existingName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

            if existingNormalised == normalisedName {
                // Check this canonical identity doesn't already have an entry for this channel.
                let alreadyHasChannel = identity.platformIds.contains { $0.channel == channel }
                guard !alreadyHasChannel else { continue }

                return link(
                    channel: channel,
                    senderId: senderId,
                    displayName: displayName,
                    canonicalId: canonicalId,
                    source: .displayNameMatch
                )
            }
        }

        return nil
    }

    // MARK: - Queries

    /// All canonical identities currently tracked.
    var allIdentities: [CanonicalIdentity] {
        Array(identities.values)
    }

    /// The number of canonical identities.
    var identityCount: Int {
        identities.count
    }

    /// The number of platform identity links.
    var linkCount: Int {
        links.count
    }

    /// Remove all links and identities. Used for testing.
    func removeAll() {
        links.removeAll()
        identities.removeAll()
        reverseIndex.removeAll()
    }

    // MARK: - Private Helpers

    /// Rebuild a canonical identity from its current platform IDs.
    private func rebuildCanonicalIdentity(_ canonicalId: String) {
        guard let siblings = reverseIndex[canonicalId] else { return }
        let existing = identities[canonicalId]

        let identity = CanonicalIdentity(
            id: canonicalId,
            displayName: existing?.displayName,
            platformIds: Array(siblings),
            entityId: existing?.entityId
        )
        identities[canonicalId] = identity
    }

    /// Generate a unique canonical identity ID.
    private func newCanonicalId() -> String {
        "cid-\(UUID().uuidString.prefix(12).lowercased())"
    }
}

// MARK: - Phone Number Utilities

/// Normalise a phone number by stripping all non-digit characters.
///
/// This produces a digit-only string suitable for suffix comparison.
private func normalisePhoneNumber(_ input: String) -> String {
    String(input.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) })
}

/// Compare two normalised phone numbers by their last 10 digits.
///
/// This handles international prefix differences (e.g. +1 vs +44).
/// Both numbers must have at least 7 digits to be considered comparable.
private func phoneNumbersMatch(_ lhs: String, _ rhs: String) -> Bool {
    guard lhs.count >= 7, rhs.count >= 7 else { return false }
    let suffixLength = min(10, min(lhs.count, rhs.count))
    return lhs.suffix(suffixLength) == rhs.suffix(suffixLength)
}
