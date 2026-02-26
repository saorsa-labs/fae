//! Doctor checks and repair actions.
//!
//! Doctor is a GUI-facing health subsystem that inspects scheduler, skills, and
//! channel configuration and provides one-click repair actions.

use crate::scheduler::{
    clear_persisted_state, load_persisted_snapshot, mark_persisted_task_due_now,
    set_persisted_task_enabled,
};
use crate::skills::{
    ManagedSkillInfo, ManagedSkillState, activate_skill, disable_skill, list_managed_skills_strict,
    rollback_skill,
};

/// Severity level for a doctor finding.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DoctorSeverity {
    Info,
    Warning,
    Error,
    Critical,
}

/// Repair action payload.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum DoctorActionKind {
    RollbackSkill { skill_id: String },
    DisableSkill { skill_id: String },
    ActivateSkill { skill_id: String },
    EnableTask { task_id: String },
    RunTaskNow { task_id: String },
    ClearSchedulerState,
    GatherDiagnostics,
}

/// Action presented to the user in Doctor UI.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct DoctorAction {
    pub id: String,
    pub label: String,
    pub kind: DoctorActionKind,
}

/// A single doctor finding.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct DoctorFinding {
    pub id: String,
    pub title: String,
    pub severity: DoctorSeverity,
    pub summary: String,
    pub evidence: Vec<String>,
    pub actions: Vec<DoctorAction>,
}

impl DoctorFinding {
    fn new(
        id: impl Into<String>,
        title: impl Into<String>,
        severity: DoctorSeverity,
        summary: impl Into<String>,
    ) -> Self {
        Self {
            id: id.into(),
            title: title.into(),
            severity,
            summary: summary.into(),
            evidence: Vec::new(),
            actions: Vec::new(),
        }
    }

    fn with_evidence(mut self, line: impl Into<String>) -> Self {
        self.evidence.push(line.into());
        self
    }

    fn with_action(mut self, label: impl Into<String>, kind: DoctorActionKind) -> Self {
        let id = action_id(&kind);
        self.actions.push(DoctorAction {
            id,
            label: label.into(),
            kind,
        });
        self
    }
}

fn action_id(kind: &DoctorActionKind) -> String {
    match kind {
        DoctorActionKind::RollbackSkill { skill_id } => format!("rollback-skill-{skill_id}"),
        DoctorActionKind::DisableSkill { skill_id } => format!("disable-skill-{skill_id}"),
        DoctorActionKind::ActivateSkill { skill_id } => format!("activate-skill-{skill_id}"),
        DoctorActionKind::EnableTask { task_id } => format!("enable-task-{task_id}"),
        DoctorActionKind::RunTaskNow { task_id } => format!("run-task-now-{task_id}"),
        DoctorActionKind::ClearSchedulerState => "clear-scheduler-state".to_owned(),
        DoctorActionKind::GatherDiagnostics => "gather-diagnostics".to_owned(),
    }
}

/// Runs all doctor checks and returns findings.
pub fn run_checks() -> Vec<DoctorFinding> {
    let mut findings = Vec::new();

    match load_persisted_snapshot() {
        Ok(snapshot) => {
            findings.extend(findings_from_scheduler_snapshot(&snapshot));
        }
        Err(err) => {
            findings.push(
                DoctorFinding::new(
                    "scheduler-state-unreadable",
                    "Scheduler state unreadable",
                    DoctorSeverity::Critical,
                    "Fae cannot parse scheduler state and may miss maintenance tasks.",
                )
                .with_evidence(err.to_string())
                .with_action(
                    "Reset scheduler state",
                    DoctorActionKind::ClearSchedulerState,
                ),
            );
        }
    }

    match list_managed_skills_strict() {
        Ok(skills) => findings.extend(findings_from_skills(&skills)),
        Err(err) => {
            findings.push(
                DoctorFinding::new(
                    "skills-registry-unreadable",
                    "Skill registry unreadable",
                    DoctorSeverity::Error,
                    "Managed skills cannot be evaluated safely.",
                )
                .with_evidence(err.to_string()),
            );
        }
    }

    findings.extend(findings_from_channel_config(&read_config_or_default()));

    if findings.is_empty() {
        findings.push(
            DoctorFinding::new(
                "doctor-clean",
                "No issues found",
                DoctorSeverity::Info,
                "Scheduler, managed skills, and channel settings look healthy.",
            )
            .with_action("Gather diagnostics", DoctorActionKind::GatherDiagnostics),
        );
    }

    findings
}

fn read_config_or_default() -> crate::config::SpeechConfig {
    let path = crate::config::SpeechConfig::default_config_path();
    if path.exists() {
        crate::config::SpeechConfig::from_file(&path).unwrap_or_default()
    } else {
        crate::config::SpeechConfig::default()
    }
}

fn findings_from_scheduler_snapshot(
    snapshot: &crate::scheduler::SchedulerSnapshot,
) -> Vec<DoctorFinding> {
    let mut findings = Vec::new();

    let mut has_builtin = false;
    for task in &snapshot.tasks {
        if task.kind == crate::scheduler::tasks::TaskKind::Builtin {
            has_builtin = true;
        }

        if !task.enabled && task.kind == crate::scheduler::tasks::TaskKind::Builtin {
            findings.push(
                DoctorFinding::new(
                    format!("scheduler-task-disabled-{}", task.id),
                    "Critical scheduler task disabled",
                    DoctorSeverity::Warning,
                    format!("Built-in task `{}` is disabled.", task.id),
                )
                .with_action(
                    "Enable task",
                    DoctorActionKind::EnableTask {
                        task_id: task.id.clone(),
                    },
                ),
            );
        }

        if task.failure_streak >= task.max_failure_streak_before_pause {
            findings.push(
                DoctorFinding::new(
                    format!("scheduler-task-paused-{}", task.id),
                    "Task paused after repeated failures",
                    DoctorSeverity::Error,
                    format!(
                        "Task `{}` reached failure threshold ({}).",
                        task.id, task.failure_streak
                    ),
                )
                .with_evidence(
                    task.last_error
                        .clone()
                        .unwrap_or_else(|| "unknown error".to_owned()),
                )
                .with_action(
                    "Enable task",
                    DoctorActionKind::EnableTask {
                        task_id: task.id.clone(),
                    },
                )
                .with_action(
                    "Run now",
                    DoctorActionKind::RunTaskNow {
                        task_id: task.id.clone(),
                    },
                ),
            );
        }
    }

    if !has_builtin {
        findings.push(
            DoctorFinding::new(
                "scheduler-missing-builtins",
                "Built-in scheduler jobs missing",
                DoctorSeverity::Warning,
                "No built-in scheduler tasks were found. Restart Fae to re-register defaults.",
            )
            .with_action(
                "Reset scheduler state",
                DoctorActionKind::ClearSchedulerState,
            ),
        );
    }

    let recent_errors = snapshot
        .history
        .iter()
        .rev()
        .take(25)
        .filter(|run| run.outcome == crate::scheduler::tasks::TaskRunOutcome::Error)
        .count();

    if recent_errors >= 5 {
        findings.push(
            DoctorFinding::new(
                "scheduler-error-burst",
                "Recent scheduler error burst",
                DoctorSeverity::Warning,
                "Scheduler has multiple recent failures.",
            )
            .with_evidence(format!("{recent_errors} errors in the most recent 25 runs"))
            .with_action("Gather diagnostics", DoctorActionKind::GatherDiagnostics),
        );
    }

    findings
}

fn findings_from_skills(skills: &[ManagedSkillInfo]) -> Vec<DoctorFinding> {
    let mut findings = Vec::new();

    for skill in skills {
        match skill.state {
            ManagedSkillState::Quarantined => {
                findings.push(
                    DoctorFinding::new(
                        format!("skill-quarantined-{}", skill.id),
                        "Skill quarantined",
                        DoctorSeverity::Warning,
                        format!("Skill `{}` is quarantined.", skill.id),
                    )
                    .with_evidence(
                        skill
                            .last_error
                            .clone()
                            .unwrap_or_else(|| "quarantine reason not recorded".to_owned()),
                    )
                    .with_action(
                        "Rollback skill",
                        DoctorActionKind::RollbackSkill {
                            skill_id: skill.id.clone(),
                        },
                    )
                    .with_action(
                        "Disable skill",
                        DoctorActionKind::DisableSkill {
                            skill_id: skill.id.clone(),
                        },
                    ),
                );
            }
            ManagedSkillState::Disabled => {
                findings.push(
                    DoctorFinding::new(
                        format!("skill-disabled-{}", skill.id),
                        "Skill disabled",
                        DoctorSeverity::Info,
                        format!("Skill `{}` is currently disabled.", skill.id),
                    )
                    .with_action(
                        "Activate skill",
                        DoctorActionKind::ActivateSkill {
                            skill_id: skill.id.clone(),
                        },
                    ),
                );
            }
            ManagedSkillState::Active => {
                if let Some(err) = &skill.last_error {
                    findings.push(
                        DoctorFinding::new(
                            format!("skill-active-error-{}", skill.id),
                            "Active skill has recorded error",
                            DoctorSeverity::Warning,
                            format!("Skill `{}` is active but has a recent error.", skill.id),
                        )
                        .with_evidence(err.clone())
                        .with_action(
                            "Rollback skill",
                            DoctorActionKind::RollbackSkill {
                                skill_id: skill.id.clone(),
                            },
                        )
                        .with_action(
                            "Disable skill",
                            DoctorActionKind::DisableSkill {
                                skill_id: skill.id.clone(),
                            },
                        ),
                    );
                }
            }
        }
    }

    findings
}

fn findings_from_channel_config(config: &crate::config::SpeechConfig) -> Vec<DoctorFinding> {
    let mut findings = Vec::new();
    for issue in crate::channels::validate_config(config) {
        let severity = match issue.severity {
            crate::channels::ChannelValidationSeverity::Warning => DoctorSeverity::Warning,
            crate::channels::ChannelValidationSeverity::Error => DoctorSeverity::Error,
        };
        findings.push(DoctorFinding::new(
            issue.id,
            issue.title,
            severity,
            issue.summary,
        ));
    }
    findings
}

/// Applies a doctor action and returns a human-readable status message.
pub fn apply_action(kind: &DoctorActionKind) -> crate::Result<String> {
    match kind {
        DoctorActionKind::RollbackSkill { skill_id } => {
            rollback_skill(skill_id)?;
            Ok(format!("Rolled back skill `{skill_id}`."))
        }
        DoctorActionKind::DisableSkill { skill_id } => {
            disable_skill(skill_id)?;
            Ok(format!("Disabled skill `{skill_id}`."))
        }
        DoctorActionKind::ActivateSkill { skill_id } => {
            activate_skill(skill_id)?;
            Ok(format!("Activated skill `{skill_id}`."))
        }
        DoctorActionKind::EnableTask { task_id } => {
            let changed = set_persisted_task_enabled(task_id, true)?;
            if changed {
                Ok(format!("Enabled scheduler task `{task_id}`."))
            } else {
                Ok(format!("Scheduler task `{task_id}` was not found."))
            }
        }
        DoctorActionKind::RunTaskNow { task_id } => {
            let changed = mark_persisted_task_due_now(task_id)?;
            if changed {
                Ok(format!("Scheduled `{task_id}` to run on next tick."))
            } else {
                Ok(format!("Scheduler task `{task_id}` was not found."))
            }
        }
        DoctorActionKind::ClearSchedulerState => {
            clear_persisted_state()?;
            Ok("Cleared scheduler state. Restart Fae to rebuild defaults.".to_owned())
        }
        DoctorActionKind::GatherDiagnostics => {
            let path = crate::diagnostics::gather_diagnostic_bundle()?;
            Ok(format!("Saved diagnostics bundle to {}", path.display()))
        }
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use super::*;

    #[test]
    fn scheduler_findings_flag_disabled_builtin() {
        let mut task = crate::scheduler::ScheduledTask::new(
            "memory_gc",
            "Memory GC",
            crate::scheduler::Schedule::Interval { secs: 60 },
        );
        task.kind = crate::scheduler::tasks::TaskKind::Builtin;
        task.enabled = false;

        let snapshot = crate::scheduler::SchedulerSnapshot {
            tasks: vec![task],
            history: Vec::new(),
        };

        let findings = findings_from_scheduler_snapshot(&snapshot);
        assert!(
            findings
                .iter()
                .any(|f| f.id.contains("scheduler-task-disabled"))
        );
    }

    #[test]
    fn skill_findings_flag_quarantine() {
        let skills = vec![ManagedSkillInfo {
            id: "calendar".to_owned(),
            name: "Calendar".to_owned(),
            version: "1.0.0".to_owned(),
            state: ManagedSkillState::Quarantined,
            last_error: Some("parse error".to_owned()),
        }];

        let findings = findings_from_skills(&skills);
        assert!(findings.iter().any(|f| f.id.contains("skill-quarantined")));
    }

    #[test]
    fn clean_result_contains_info_card() {
        let mut builtin = crate::scheduler::ScheduledTask::new(
            "memory_gc",
            "Memory GC",
            crate::scheduler::Schedule::Interval { secs: 60 },
        );
        builtin.kind = crate::scheduler::tasks::TaskKind::Builtin;
        let scheduler = crate::scheduler::SchedulerSnapshot {
            tasks: vec![builtin],
            history: Vec::new(),
        };
        let mut findings = findings_from_scheduler_snapshot(&scheduler);
        let skills = findings_from_skills(&[]);
        findings.extend(skills);
        if findings.is_empty() {
            findings.push(
                DoctorFinding::new(
                    "doctor-clean",
                    "No issues found",
                    DoctorSeverity::Info,
                    "healthy",
                )
                .with_action("Gather diagnostics", DoctorActionKind::GatherDiagnostics),
            );
        }

        assert!(findings.iter().any(|f| f.id == "doctor-clean"));
    }
}
