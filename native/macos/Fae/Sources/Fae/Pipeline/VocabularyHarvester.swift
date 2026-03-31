import Contacts
import EventKit
import Foundation

/// Harvests proper names from macOS Contacts and Calendar for post-ASR vocabulary correction.
///
/// Produces `PersonalLexicon` entries from:
/// - Contact names (first + last, nickname, organisation)
/// - Calendar event titles (next 30 days)
///
/// Run by the scheduler at enrollment completion and daily at 04:00.
/// Uses system frameworks directly (CNContactStore, EKEventStore) with
/// graceful degradation when permissions are not granted.
enum VocabularyHarvester {

    /// Result of a harvest operation.
    struct HarvestResult: Sendable {
        /// Number of new entries added to the lexicon.
        let newEntries: Int
        /// Number of entries that already existed (merged variants only).
        let mergedEntries: Int
        /// Sources that were skipped due to missing permissions.
        let skippedSources: [String]
    }

    /// Harvest names from Contacts and Calendar, merge into the given lexicon.
    ///
    /// - Parameter lexicon: The `PersonalLexicon` to write into.
    /// - Returns: Summary of what was harvested.
    static func harvest(into lexicon: PersonalLexicon) async -> HarvestResult {
        var candidates: [(canonical: String, variants: [String], source: String)] = []
        var skipped: [String] = []

        // Contacts.
        let contactNames = harvestContacts()
        if let names = contactNames {
            for name in names {
                candidates.append((canonical: name, variants: [], source: "contact"))
            }
        } else {
            skipped.append("contacts")
        }

        // Calendar.
        let calendarNames = harvestCalendarNames()
        if let names = calendarNames {
            for name in names {
                candidates.append((canonical: name, variants: [], source: "calendar"))
            }
        } else {
            skipped.append("calendar")
        }

        guard !candidates.isEmpty else {
            return HarvestResult(newEntries: 0, mergedEntries: 0, skippedSources: skipped)
        }

        let countBefore = await lexicon.count
        let added = await lexicon.mergeAll(candidates)
        let countAfter = await lexicon.count
        await lexicon.save()

        let merged = (countAfter - countBefore)
        NSLog(
            "VocabularyHarvester: harvested %d candidates, %d new, %d merged, skipped: %@",
            candidates.count, added, merged - added, skipped.joined(separator: ", ")
        )

        return HarvestResult(
            newEntries: added,
            mergedEntries: candidates.count - added,
            skippedSources: skipped
        )
    }

    // MARK: - Contacts

    /// Harvest unique proper names from the user's Contacts.
    /// Returns nil if permission is not granted (caller should record as skipped).
    private static func harvestContacts() -> [String]? {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        guard status == .authorized else {
            NSLog("VocabularyHarvester: contacts permission not granted (status=%d)", status.rawValue)
            return nil
        }

        let store = CNContactStore()
        let keysToFetch: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactNicknameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
        ]

        var names: Set<String> = []

        do {
            let request = CNContactFetchRequest(keysToFetch: keysToFetch)
            request.sortOrder = .givenName

            try store.enumerateContacts(with: request) { contact, _ in
                // Given name.
                let given = contact.givenName.trimmingCharacters(in: .whitespacesAndNewlines)
                if given.count >= 2 { names.insert(given) }

                // Family name.
                let family = contact.familyName.trimmingCharacters(in: .whitespacesAndNewlines)
                if family.count >= 2 { names.insert(family) }

                // Full name (if both parts present).
                if given.count >= 2, family.count >= 2 {
                    names.insert("\(given) \(family)")
                }

                // Nickname.
                let nick = contact.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
                if nick.count >= 2 { names.insert(nick) }

                // Organisation.
                let org = contact.organizationName.trimmingCharacters(in: .whitespacesAndNewlines)
                if org.count >= 3 { names.insert(org) }
            }
        } catch {
            NSLog("VocabularyHarvester: contacts fetch error — %@", error.localizedDescription)
            return nil
        }

        return Array(names)
    }

    // MARK: - Calendar

    /// Harvest unique proper names/titles from calendar events in the next 30 days.
    /// Returns nil if permission is not granted.
    private static func harvestCalendarNames() -> [String]? {
        let status = EKEventStore.authorizationStatus(for: .event)
        let authorized: Bool
        if #available(macOS 14.0, *) {
            authorized = status == .fullAccess || status == .writeOnly
        } else {
            authorized = status == .authorized
        }

        guard authorized else {
            NSLog("VocabularyHarvester: calendar permission not granted (status=%d)", status.rawValue)
            return nil
        }

        let store = EKEventStore()
        let now = Date()
        guard let endDate = Calendar.current.date(byAdding: .day, value: 30, to: now) else {
            return nil
        }

        let predicate = store.predicateForEvents(withStart: now, end: endDate, calendars: nil)
        let events = store.events(matching: predicate)

        var names: Set<String> = []

        for event in events {
            guard let title = event.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                  title.count >= 3 else { continue }

            // Extract probable proper names from event titles.
            // Words that start with uppercase and are 2+ chars are likely names.
            let words = title.components(separatedBy: .whitespacesAndNewlines)
            for word in words {
                let cleaned = word.trimmingCharacters(in: .punctuationCharacters)
                guard cleaned.count >= 2 else { continue }
                guard let first = cleaned.first, first.isUppercase else { continue }
                // Skip common non-name words.
                let lower = cleaned.lowercased()
                guard !Self.commonWords.contains(lower) else { continue }
                names.insert(cleaned)
            }

            // Also store multi-word sequences that look like names (e.g. "Meeting with John Smith").
            // Look for "with <Name>" patterns.
            if let withRange = title.range(of: " with ", options: .caseInsensitive) {
                let afterWith = title[withRange.upperBound...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if afterWith.count >= 2, afterWith.first?.isUppercase == true {
                    // Take up to 3 words after "with".
                    let nameWords = afterWith.components(separatedBy: .whitespaces).prefix(3)
                    let probableName = nameWords
                        .filter { $0.first?.isUppercase == true && $0.count >= 2 }
                        .joined(separator: " ")
                    if probableName.count >= 2 { names.insert(probableName) }
                }
            }
        }

        return Array(names)
    }

    /// Common English words that should not be harvested as proper names.
    private static let commonWords: Set<String> = [
        "meeting", "call", "review", "sync", "standup", "lunch", "dinner",
        "breakfast", "the", "with", "for", "and", "from", "about", "weekly",
        "monthly", "daily", "annual", "update", "check", "team", "project",
        "sprint", "retro", "demo", "planning", "session", "workshop",
        "appointment", "reminder", "birthday", "holiday", "vacation",
        "conference", "event", "deadline", "due", "follow", "new", "old",
    ]
}
