//! Built-in permission-gated skill definitions.
//!
//! Each skill maps to one or more [`PermissionKind`] values and provides a
//! prompt fragment that is injected when the skill is active.

use crate::permissions::PermissionKind;
use crate::skills::trait_def::{FaeSkill, SkillSet};

// ---------------------------------------------------------------------------
// Macro to reduce boilerplate for simple single-permission skills.
// ---------------------------------------------------------------------------

macro_rules! define_skill {
    (
        $struct_name:ident,
        name: $name:expr,
        description: $desc:expr,
        permissions: [$($perm:expr),+ $(,)?],
        prompt: $prompt:expr $(,)?
    ) => {
        /// Built-in skill: see [`FaeSkill`] impl.
        pub struct $struct_name;

        impl FaeSkill for $struct_name {
            fn name(&self) -> &str {
                $name
            }
            fn description(&self) -> &str {
                $desc
            }
            fn required_permissions(&self) -> &[PermissionKind] {
                &[$($perm),+]
            }
            fn prompt_fragment(&self) -> &str {
                $prompt
            }
        }
    };
}

// ---------------------------------------------------------------------------
// Skill definitions
// ---------------------------------------------------------------------------

define_skill!(
    CalendarSkill,
    name: "calendar",
    description: "Schedule management — view, create, and modify calendar events",
    permissions: [PermissionKind::Calendar],
    prompt: "You have access to the user's calendar. When they ask about their schedule, \
upcoming events, or want to create/modify events, use the calendar tool. \
Be specific about dates and times. Always confirm before creating or changing events.",
);

define_skill!(
    ContactsSkill,
    name: "contacts",
    description: "Address book — look up names, emails, phone numbers",
    permissions: [PermissionKind::Contacts],
    prompt: "You have access to the user's contacts. When they mention a person by name, \
you can look up their contact details (email, phone, address). Use this to \
personalise interactions and help with communication tasks.",
);

define_skill!(
    MailSkill,
    name: "mail",
    description: "Email — read, compose, and send messages",
    permissions: [PermissionKind::Mail],
    prompt: "You have access to the user's email. You can read recent messages, \
compose drafts, and send emails on their behalf. Always confirm the recipient \
and content before sending. Summarise long email threads concisely.",
);

define_skill!(
    RemindersSkill,
    name: "reminders",
    description: "Task management — create, complete, and list reminders",
    permissions: [PermissionKind::Reminders],
    prompt: "You have access to the user's reminders. You can create new reminders \
with due dates, mark them complete, and list outstanding tasks. Suggest \
reasonable due dates when the user doesn't specify one.",
);

define_skill!(
    FilesSkill,
    name: "files",
    description: "File system — read, write, and organise documents",
    permissions: [PermissionKind::Files],
    prompt: "You have access to the user's file system within sandboxed locations. \
You can read documents, create new files, and help organise folders. \
Always respect file permissions and never delete without explicit confirmation.",
);

define_skill!(
    NotificationsSkill,
    name: "notifications",
    description: "System notifications — deliver timely alerts and updates",
    permissions: [PermissionKind::Notifications],
    prompt: "You can send system notifications to alert the user about important events, \
reminders, or completed tasks. Use notifications sparingly — only for genuinely \
time-sensitive or user-requested alerts. Never spam.",
);

define_skill!(
    LocationSkill,
    name: "location",
    description: "Location services — weather, local search, directions",
    permissions: [PermissionKind::Location],
    prompt: "You have access to the user's approximate location. Use this for weather \
forecasts, local business recommendations, and directions. Never share the \
user's location with external services without explicit consent.",
);

define_skill!(
    DesktopAutomationSkill,
    name: "desktop_automation",
    description: "Desktop control — screenshots, window management, AppleScript",
    permissions: [PermissionKind::DesktopAutomation],
    prompt: "You have desktop automation access including screenshots, window management, \
and AppleScript execution. Use this to help the user automate repetitive tasks, \
take screenshots for reference, or control applications. Always explain what \
you're about to automate before executing.",
);

/// Create a [`SkillSet`] containing all built-in permission-gated skills.
pub fn builtin_skills() -> SkillSet {
    SkillSet::new(vec![
        Box::new(CalendarSkill),
        Box::new(ContactsSkill),
        Box::new(MailSkill),
        Box::new(RemindersSkill),
        Box::new(FilesSkill),
        Box::new(NotificationsSkill),
        Box::new(LocationSkill),
        Box::new(DesktopAutomationSkill),
    ])
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use super::*;
    use crate::permissions::PermissionStore;

    #[test]
    fn all_builtins_have_nonempty_fields() {
        let set = builtin_skills();
        assert_eq!(set.len(), 8);

        for skill in set.all() {
            assert!(!skill.name().is_empty(), "skill name empty");
            assert!(
                !skill.description().is_empty(),
                "description empty for {}",
                skill.name()
            );
            assert!(
                !skill.required_permissions().is_empty(),
                "no permissions for {}",
                skill.name()
            );
            assert!(
                !skill.prompt_fragment().is_empty(),
                "empty prompt for {}",
                skill.name()
            );
        }
    }

    #[test]
    fn no_duplicated_skill_names() {
        let set = builtin_skills();
        let mut seen = std::collections::HashSet::new();
        for skill in set.all() {
            assert!(
                seen.insert(skill.name()),
                "duplicate skill name: {}",
                skill.name()
            );
        }
    }

    #[test]
    fn empty_store_no_builtins_available() {
        let set = builtin_skills();
        let store = PermissionStore::default();
        assert!(set.available(&store).is_empty());
    }

    #[test]
    fn grant_calendar_activates_calendar_skill() {
        let set = builtin_skills();
        let mut store = PermissionStore::default();
        store.grant(PermissionKind::Calendar);

        let avail = set.available(&store);
        assert_eq!(avail.len(), 1);
        assert_eq!(avail[0].name(), "calendar");
    }

    #[test]
    fn grant_all_activates_all_skills() {
        let set = builtin_skills();
        let mut store = PermissionStore::default();

        // Grant every permission except Microphone (not a skill permission)
        for kind in PermissionKind::all() {
            store.grant(*kind);
        }

        assert_eq!(set.available(&store).len(), 8);
    }

    #[test]
    fn builtin_skill_names_are_valid_identifiers() {
        let set = builtin_skills();
        for skill in set.all() {
            assert!(
                skill
                    .name()
                    .chars()
                    .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_'),
                "invalid skill name: {}",
                skill.name()
            );
        }
    }

    #[test]
    fn prompt_fragments_are_reasonable_length() {
        let set = builtin_skills();
        for skill in set.all() {
            let len = skill.prompt_fragment().len();
            assert!(
                (50..=1000).contains(&len),
                "prompt fragment for {} has suspicious length: {len}",
                skill.name()
            );
        }
    }
}
