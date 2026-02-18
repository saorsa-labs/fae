//! The [`FaeSkill`] trait and [`SkillSet`] collection for permission-gated skills.
//!
//! Each skill declares the permissions it needs.  The [`SkillSet`] filters
//! registered skills against a [`PermissionStore`] to determine which are
//! currently available.

use crate::permissions::{PermissionKind, PermissionStore};

/// A capability-gated skill that Fae can activate.
///
/// Implementors declare which permissions they require and provide a prompt
/// fragment that is injected into the system prompt when the skill is active.
pub trait FaeSkill: Send + Sync {
    /// Unique machine-readable identifier (e.g. `"calendar"`).
    fn name(&self) -> &str;

    /// Short human-readable description shown in settings / onboarding UI.
    fn description(&self) -> &str;

    /// The set of permissions this skill requires to operate.
    ///
    /// An empty slice means the skill has no permission gate and is always
    /// available (though this is uncommon for built-in skills).
    fn required_permissions(&self) -> &[PermissionKind];

    /// Whether this skill is currently available given the user's permission grants.
    ///
    /// Default implementation returns `true` only when **all** required
    /// permissions are granted.
    fn is_available(&self, store: &PermissionStore) -> bool {
        self.required_permissions()
            .iter()
            .all(|perm| store.is_granted(*perm))
    }

    /// The prompt fragment injected into the system prompt when the skill is active.
    ///
    /// Should be a concise behavioural instruction telling the LLM when and how
    /// to exercise this capability.
    fn prompt_fragment(&self) -> &str;
}

/// A collection of registered skills with permission-aware filtering.
pub struct SkillSet {
    skills: Vec<Box<dyn FaeSkill>>,
}

impl SkillSet {
    /// Create a new skill set from a list of skills.
    pub fn new(skills: Vec<Box<dyn FaeSkill>>) -> Self {
        Self { skills }
    }

    /// Return all registered skills.
    pub fn all(&self) -> &[Box<dyn FaeSkill>] {
        &self.skills
    }

    /// Return only the skills that are available given the current permission state.
    pub fn available(&self, store: &PermissionStore) -> Vec<&dyn FaeSkill> {
        self.skills
            .iter()
            .filter(|s| s.is_available(store))
            .map(|s| s.as_ref())
            .collect()
    }

    /// Return only the skills that are **not** available (missing permissions).
    pub fn unavailable(&self, store: &PermissionStore) -> Vec<&dyn FaeSkill> {
        self.skills
            .iter()
            .filter(|s| !s.is_available(store))
            .map(|s| s.as_ref())
            .collect()
    }

    /// Collect prompt fragments from all available skills into a single string.
    ///
    /// Each fragment is separated by a blank line.
    pub fn active_prompt_fragments(&self, store: &PermissionStore) -> String {
        self.available(store)
            .iter()
            .map(|s| s.prompt_fragment())
            .collect::<Vec<_>>()
            .join("\n\n")
    }

    /// Look up a skill by name.
    pub fn get(&self, name: &str) -> Option<&dyn FaeSkill> {
        self.skills
            .iter()
            .find(|s| s.name() == name)
            .map(|s| s.as_ref())
    }

    /// Number of registered skills.
    pub fn len(&self) -> usize {
        self.skills.len()
    }

    /// Whether the set is empty.
    pub fn is_empty(&self) -> bool {
        self.skills.is_empty()
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use super::*;

    /// Minimal test skill for unit tests.
    struct TestSkill {
        name: &'static str,
        perms: &'static [PermissionKind],
        fragment: &'static str,
    }

    impl FaeSkill for TestSkill {
        fn name(&self) -> &str {
            self.name
        }
        fn description(&self) -> &str {
            "test skill"
        }
        fn required_permissions(&self) -> &[PermissionKind] {
            self.perms
        }
        fn prompt_fragment(&self) -> &str {
            self.fragment
        }
    }

    fn make_set() -> SkillSet {
        SkillSet::new(vec![
            Box::new(TestSkill {
                name: "cal",
                perms: &[PermissionKind::Calendar],
                fragment: "Use calendar.",
            }),
            Box::new(TestSkill {
                name: "mail",
                perms: &[PermissionKind::Mail],
                fragment: "Send mail.",
            }),
            Box::new(TestSkill {
                name: "multi",
                perms: &[PermissionKind::Files, PermissionKind::DesktopAutomation],
                fragment: "Automate files.",
            }),
        ])
    }

    #[test]
    fn empty_store_means_no_skills_available() {
        let set = make_set();
        let store = PermissionStore::default();
        assert!(set.available(&store).is_empty());
        assert_eq!(set.unavailable(&store).len(), 3);
    }

    #[test]
    fn granting_permission_activates_skill() {
        let set = make_set();
        let mut store = PermissionStore::default();
        store.grant(PermissionKind::Calendar);

        let avail = set.available(&store);
        assert_eq!(avail.len(), 1);
        assert_eq!(avail[0].name(), "cal");
    }

    #[test]
    fn multi_permission_skill_needs_all_granted() {
        let set = make_set();
        let mut store = PermissionStore::default();
        store.grant(PermissionKind::Files);

        // Only Files granted — multi needs Files + DesktopAutomation
        assert!(set.available(&store).iter().all(|s| s.name() != "multi"));

        store.grant(PermissionKind::DesktopAutomation);
        assert!(set.available(&store).iter().any(|s| s.name() == "multi"));
    }

    #[test]
    fn active_prompt_fragments_joins_available() {
        let set = make_set();
        let mut store = PermissionStore::default();
        store.grant(PermissionKind::Calendar);
        store.grant(PermissionKind::Mail);

        let fragments = set.active_prompt_fragments(&store);
        assert!(fragments.contains("Use calendar."));
        assert!(fragments.contains("Send mail."));
        assert!(!fragments.contains("Automate files."));
    }

    #[test]
    fn get_by_name() {
        let set = make_set();
        assert!(set.get("cal").is_some());
        assert!(set.get("nonexistent").is_none());
    }

    #[test]
    fn len_and_is_empty() {
        let set = make_set();
        assert_eq!(set.len(), 3);
        assert!(!set.is_empty());

        let empty = SkillSet::new(vec![]);
        assert!(empty.is_empty());
    }

    #[test]
    fn denied_permission_makes_skill_unavailable() {
        let set = make_set();
        let mut store = PermissionStore::default();
        store.grant(PermissionKind::Calendar);
        assert_eq!(set.available(&store).len(), 1);

        store.deny(PermissionKind::Calendar);
        assert!(set.available(&store).is_empty());
    }
}
