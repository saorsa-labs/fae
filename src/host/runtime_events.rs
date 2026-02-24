//! Runtime event and progress event to JSON mapping.
//!
//! Extracted from `handler.rs` — these free functions convert internal
//! event types into FFI-compatible JSON payloads for the Swift host.

use crate::progress::ProgressEvent;
use crate::runtime::RuntimeEvent;

/// Convert a [`ProgressEvent`] to a JSON payload for the FFI event bus.
pub(crate) fn progress_event_to_json(evt: &ProgressEvent) -> serde_json::Value {
    match evt {
        ProgressEvent::DownloadStarted {
            repo_id,
            filename,
            total_bytes,
        } => serde_json::json!({
            "stage": "download_started",
            "repo_id": repo_id,
            "filename": filename,
            "total_bytes": total_bytes,
        }),
        ProgressEvent::DownloadProgress {
            repo_id,
            filename,
            bytes_downloaded,
            total_bytes,
        } => serde_json::json!({
            "stage": "download_progress",
            "repo_id": repo_id,
            "filename": filename,
            "bytes_downloaded": bytes_downloaded,
            "total_bytes": total_bytes,
        }),
        ProgressEvent::DownloadComplete { repo_id, filename } => serde_json::json!({
            "stage": "download_complete",
            "repo_id": repo_id,
            "filename": filename,
        }),
        ProgressEvent::Cached { repo_id, filename } => serde_json::json!({
            "stage": "cached",
            "repo_id": repo_id,
            "filename": filename,
        }),
        ProgressEvent::LoadStarted { model_name } => serde_json::json!({
            "stage": "load_started",
            "model_name": model_name,
        }),
        ProgressEvent::LoadComplete {
            model_name,
            duration_secs,
        } => serde_json::json!({
            "stage": "load_complete",
            "model_name": model_name,
            "duration_secs": duration_secs,
        }),
        ProgressEvent::AggregateProgress {
            bytes_downloaded,
            total_bytes,
            files_complete,
            files_total,
        } => serde_json::json!({
            "stage": "aggregate_progress",
            "bytes_downloaded": bytes_downloaded,
            "total_bytes": total_bytes,
            "files_complete": files_complete,
            "files_total": files_total,
        }),
        ProgressEvent::DownloadPlanReady { plan } => serde_json::json!({
            "stage": "download_plan_ready",
            "file_count": plan.files.len(),
            "total_bytes": plan.total_bytes(),
            "needs_download": plan.needs_download(),
        }),
        ProgressEvent::Error { message } => serde_json::json!({
            "stage": "error",
            "message": message,
        }),
    }
}

/// Map a [`RuntimeEvent`] to an FFI-compatible event name and JSON payload.
pub(crate) fn map_runtime_event(event: &RuntimeEvent) -> (String, serde_json::Value) {
    use crate::pipeline::messages::ControlEvent;
    match event {
        RuntimeEvent::Control(ControlEvent::AudioDeviceChanged { device_name }) => (
            "pipeline.control".to_owned(),
            serde_json::json!({
                "action": "audio_device_changed",
                "device_name": device_name,
            }),
        ),
        RuntimeEvent::Control(ControlEvent::DegradedMode { mode }) => (
            "pipeline.control".to_owned(),
            serde_json::json!({
                "action": "degraded_mode",
                "mode": mode,
            }),
        ),
        RuntimeEvent::Control(c) => (
            "pipeline.control".to_owned(),
            serde_json::json!({"control": format!("{c:?}")}),
        ),
        RuntimeEvent::Transcription(t) => (
            "pipeline.transcription".to_owned(),
            serde_json::json!({"text": t.text, "is_final": t.is_final}),
        ),
        RuntimeEvent::AssistantSentence(s) => (
            "pipeline.assistant_sentence".to_owned(),
            serde_json::json!({"text": s.text, "is_final": s.is_final}),
        ),
        RuntimeEvent::AssistantGenerating { active } => (
            "pipeline.generating".to_owned(),
            serde_json::json!({"active": active}),
        ),
        RuntimeEvent::ToolExecuting { name } => (
            "pipeline.tool_executing".to_owned(),
            serde_json::json!({"name": name}),
        ),
        RuntimeEvent::ToolCall {
            id,
            name,
            input_json,
        } => (
            "pipeline.tool_call".to_owned(),
            serde_json::json!({"id": id, "name": name, "input_json": input_json}),
        ),
        RuntimeEvent::ToolResult {
            id,
            name,
            success,
            output_text,
        } => (
            "pipeline.tool_result".to_owned(),
            serde_json::json!({
                "id": id,
                "name": name,
                "success": success,
                "output_text": output_text,
            }),
        ),
        RuntimeEvent::AssistantAudioLevel { rms } => (
            "pipeline.audio_level".to_owned(),
            serde_json::json!({"rms": rms}),
        ),
        RuntimeEvent::AssistantViseme { mouth_png } => (
            "pipeline.viseme".to_owned(),
            serde_json::json!({"mouth_png": mouth_png}),
        ),
        RuntimeEvent::MemoryRecall { query, hits } => (
            "pipeline.memory_recall".to_owned(),
            serde_json::json!({"query": query, "hits": hits}),
        ),
        RuntimeEvent::MemoryWrite { op, target_id } => (
            "pipeline.memory_write".to_owned(),
            serde_json::json!({"op": op, "target_id": target_id}),
        ),
        RuntimeEvent::MemoryConflict {
            existing_id,
            replacement_id,
        } => (
            "pipeline.memory_conflict".to_owned(),
            serde_json::json!({"existing_id": existing_id, "replacement_id": replacement_id}),
        ),
        RuntimeEvent::MemoryMigration { from, to, success } => (
            "pipeline.memory_migration".to_owned(),
            serde_json::json!({"from": from, "to": to, "success": success}),
        ),
        RuntimeEvent::ModelSelectionPrompt {
            candidates,
            timeout_secs,
        } => (
            "pipeline.model_selection_prompt".to_owned(),
            serde_json::json!({"candidates": candidates, "timeout_secs": timeout_secs}),
        ),
        RuntimeEvent::ModelSelected { provider_model } => (
            "pipeline.model_selected".to_owned(),
            serde_json::json!({"provider_model": provider_model}),
        ),
        RuntimeEvent::VoiceCommandDetected { command } => (
            "pipeline.voice_command".to_owned(),
            serde_json::json!({"command": command}),
        ),
        RuntimeEvent::PermissionsChanged { granted } => (
            "pipeline.permissions_changed".to_owned(),
            serde_json::json!({"granted": granted}),
        ),
        RuntimeEvent::ModelSwitchRequested { target } => (
            "pipeline.model_switch_requested".to_owned(),
            serde_json::json!({"target": target}),
        ),
        RuntimeEvent::ConversationSnapshot { entries } => {
            let items: Vec<serde_json::Value> = entries
                .iter()
                .map(|e| serde_json::json!({"role": format!("{:?}", e.role), "text": e.text}))
                .collect();
            (
                "pipeline.conversation_snapshot".to_owned(),
                serde_json::json!({"entries": items}),
            )
        }
        RuntimeEvent::MicStatus { active } => (
            "pipeline.mic_status".to_owned(),
            serde_json::json!({"active": active}),
        ),
        RuntimeEvent::ConversationCanvasVisibility { visible } => (
            "pipeline.canvas_visibility".to_owned(),
            serde_json::json!({"visible": visible}),
        ),
        RuntimeEvent::ConversationVisibility { visible } => (
            "pipeline.conversation_visibility".to_owned(),
            serde_json::json!({"visible": visible}),
        ),
        RuntimeEvent::ProviderFallback { primary, error } => (
            "pipeline.provider_fallback".to_owned(),
            serde_json::json!({"primary": primary, "error": error}),
        ),
        RuntimeEvent::IntelligenceExtraction {
            items_count,
            actions_count,
        } => (
            "pipeline.intelligence_extraction".to_owned(),
            serde_json::json!({"items_count": items_count, "actions_count": actions_count}),
        ),
        RuntimeEvent::ProactiveBriefingReady { item_count } => (
            "pipeline.briefing_ready".to_owned(),
            serde_json::json!({"item_count": item_count}),
        ),
        RuntimeEvent::RelationshipUpdate { name } => (
            "pipeline.relationship_update".to_owned(),
            serde_json::json!({"name": name}),
        ),
        RuntimeEvent::SkillProposal { skill_name } => (
            "pipeline.skill_proposal".to_owned(),
            serde_json::json!({"skill_name": skill_name}),
        ),
        RuntimeEvent::NoiseBudgetUpdate { remaining } => (
            "pipeline.noise_budget".to_owned(),
            serde_json::json!({"remaining": remaining}),
        ),
        RuntimeEvent::OrbMoodUpdate { feeling, palette } => (
            "orb.state_changed".to_owned(),
            serde_json::json!({"feeling": feeling, "palette": palette}),
        ),
        RuntimeEvent::PipelineTiming { stage, duration_ms } => (
            "pipeline.timing".to_owned(),
            serde_json::json!({"stage": stage, "duration_ms": duration_ms}),
        ),
        RuntimeEvent::BackgroundTaskStarted {
            task_id,
            description,
        } => (
            "background_task.started".to_owned(),
            serde_json::json!({"task_id": task_id, "description": description}),
        ),
        RuntimeEvent::BackgroundTaskCompleted {
            task_id,
            success,
            summary,
        } => (
            "background_task.completed".to_owned(),
            serde_json::json!({"task_id": task_id, "success": success, "summary": summary}),
        ),
        RuntimeEvent::ApprovalResolved {
            request_id,
            approved,
            source,
            speaker_verified,
        } => (
            "approval.resolved".to_owned(),
            serde_json::json!({
                "request_id": request_id.to_string(),
                "approved": approved,
                "source": source,
                "speaker_verified": speaker_verified,
            }),
        ),
        RuntimeEvent::VoiceIdentityDecision {
            accepted,
            reason,
            similarity,
        } => (
            "voice_identity.decision".to_owned(),
            serde_json::json!({
                "accepted": accepted,
                "reason": reason,
                "similarity": similarity,
            }),
        ),
        RuntimeEvent::VoiceprintEnrollmentProgress {
            sample_count,
            required_samples,
            enrolled,
        } => (
            "onboarding.voiceprint.progress".to_owned(),
            serde_json::json!({
                "sample_count": sample_count,
                "required_samples": required_samples,
                "enrolled": enrolled,
            }),
        ),
    }
}
