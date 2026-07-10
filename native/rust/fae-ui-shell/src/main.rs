// Tests may use `.expect()`/`.unwrap()` per the project convention (production
// code stays panic-free). The orb-shell CI lints `--all-targets` with
// `-D clippy::expect_used`/`unwrap_used`, which also covers `#[cfg(test)]` code,
// so scope those two allows to test builds only.
#![cfg_attr(test, allow(clippy::expect_used, clippy::unwrap_used))]

/// Orb-host-owns-state: direct daemon subscription (own connection, drives the
/// orb mode + voice ride via the grace-hold state machine). Unix-only (the orb
/// host is a Unix GUI app; there is no non-Unix target). Default ON at runtime
/// unless `FAE_ORB_DAEMON_AUDIO=0/false/off/no`.
#[cfg(unix)]
mod daemon_audio_bridge;
mod menu;
mod orb_state;
mod protocol;

use std::{
    error::Error,
    io::{self, BufRead, Write},
    thread,
    time::{Duration, Instant},
};

use menu::{MenuAction, OrbMenu};
use protocol::{
    AudioPatch, FaeUiState, SchedulerTask, SettingItem, SettingOption, SettingsCard,
    SettingsSection, ShellCommand, SkillSummary,
};
use tao::{
    dpi::{LogicalPosition, LogicalSize, PhysicalPosition, PhysicalSize},
    event::{ElementState, Event, KeyEvent, MouseButton, StartCause, WindowEvent},
    event_loop::{ControlFlow, EventLoopBuilder},
    keyboard::KeyCode,
    window::{Window, WindowBuilder},
};
use wgpu::util::DeviceExt;
use wry::{WebView, WebViewBuilder};

#[cfg(target_os = "macos")]
use tao::platform::macos::WindowExtMacOS;

#[derive(Debug)]
enum UserEvent {
    Menu(muda::MenuEvent),
    Bridge(ShellCommand),
    PanelAction(String),
    /// Voice spine / orb-host-owns-state: a daemon-originated orb event. The
    /// render loop runs the grace-hold state machine (`OrbStateMachine`) on
    /// generating/level/ended/reset and applies the audio level to the orb.
    /// Carried unconditionally (cheap enum); the bridge only emits when compiled
    /// in + enabled.
    DaemonOrb(orb_state::OrbDaemonEvent),
}

#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
struct Uniforms {
    resolution: [f32; 2],
    time: f32,
    audio: f32,
    quality: f32,
    active: f32,
    status_progress: f32,
    status_visible: f32,
    /// Pipeline mode for fog behavior: 0 quiescent, 1 listening, 2 thinking,
    /// 3 speaking. Eased on the CPU so behavior cross-fades.
    mode: f32,
    /// Emotional hue bias 0..1: 0 = ember/smoke (concern), 0.5 = neutral
    /// gold, 1 = bright cream (delight). Eased.
    warmth: f32,
    /// Emotional motion scale 0..1: calm stillness to playful churn. Eased.
    energy: f32,
    _pad: f32,
}

impl Uniforms {
    fn new(size: PhysicalSize<u32>) -> Self {
        Self {
            resolution: [size.width as f32, size.height as f32],
            time: 0.0,
            audio: 0.0,
            quality: 1.0,
            active: 1.0,
            status_progress: 0.0,
            status_visible: 0.0,
            mode: 0.0,
            warmth: 0.5,
            energy: 0.4,
            _pad: 0.0,
        }
    }
}

/// Map a Swift OrbFeeling rawValue to (warmth, energy) fog targets.
/// Unknown or absent feelings read as neutral.
fn feeling_targets(feeling: Option<&str>) -> (f32, f32) {
    match feeling.unwrap_or("neutral") {
        "calm" => (0.45, 0.22),
        "curiosity" => (0.60, 0.62),
        "warmth" => (0.78, 0.45),
        "concern" => (0.12, 0.55),
        "delight" => (0.92, 0.72),
        "focus" => (0.42, 0.30),
        "playful" => (0.82, 0.85),
        _ => (0.50, 0.40),
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum WebPanelKind {
    Scheduler,
    Settings,
    Skills,
}

struct WebPanel {
    kind: WebPanelKind,
    window: Window,
    webview: WebView,
}

#[derive(Clone, Debug)]
struct TranscriptMessage {
    role: String,
    text: String,
}

#[derive(Debug)]
struct OrbUiModel {
    status_phase: String,
    status_message: String,
    status_progress: Option<f32>,
    /// Latest pipeline mode from the State command — drives the pill's live
    /// status line (Listening / Thinking… / Speaking).
    ui_mode: FaeUiState,
    messages: Vec<TranscriptMessage>,
    /// Accumulated assistant response that has not yet been committed to the
    /// finalized transcript. Rendered as one transient trailing message.
    streaming_text: String,

    scheduler_tasks: Vec<SchedulerTask>,
    skills: Vec<SkillSummary>,
    settings_sections: Vec<SettingsSection>,
    settings_cards: Vec<SettingsCard>,
    /// Orb-host-owns-state: the current info-indicator set (green-dot pill line).
    /// Populated by `info.update` events from the daemon bridge.
    info_items: orb_state::InfoItems,
    /// Voice-mute state (`tts.speakReplies`): drives the pill speaker glyph.
    /// Pushed by Swift on connect and whenever the mute toggles.
    voice_muted: bool,
}

impl OrbUiModel {
    fn new() -> Self {
        Self {
            status_phase: "starting".to_string(),
            status_message: "Starting Fae".to_string(),
            status_progress: None,
            ui_mode: FaeUiState::Quiescent,
            messages: Vec::new(),
            streaming_text: String::new(),
            scheduler_tasks: Vec::new(),
            skills: Vec::new(),
            settings_sections: Vec::new(),
            settings_cards: Vec::new(),
            info_items: orb_state::InfoItems::default(),
            voice_muted: false,
        }
    }

    /// True once the user has said or typed anything this session — gates the
    /// first-run "Click me and speak" teaching hint.
    fn has_user_message(&self) -> bool {
        self.messages
            .iter()
            .any(|message| message.role.eq_ignore_ascii_case("user"))
    }

    fn set_status(&mut self, phase: String, message: String, progress: Option<f32>) {
        self.status_phase = phase;
        self.status_message = message;
        self.status_progress = progress.map(|value| value.clamp(0.0, 1.0));
    }

    fn push_message(&mut self, role: String, text: String) {
        if text.trim().is_empty() {
            return;
        }
        self.messages.push(TranscriptMessage { role, text });
        if self.messages.len() > 80 {
            self.messages.drain(0..self.messages.len() - 80);
        }
    }

    fn clear_messages(&mut self) {
        self.messages.clear();
    }

    fn set_streaming_text(&mut self, text: String) {
        self.streaming_text = text;
    }

    fn has_distinct_streaming_text(&self) -> bool {
        let stream = self.streaming_text.trim();
        if stream.is_empty() {
            return false;
        }
        !self.messages.last().is_some_and(|message| {
            (message.role.eq_ignore_ascii_case("fae")
                || message.role.eq_ignore_ascii_case("assistant"))
                && message.text.trim() == stream
        })
    }

    fn set_voice_muted(&mut self, muted: bool) {
        self.voice_muted = muted;
    }

    fn set_scheduler_tasks(&mut self, tasks: Vec<SchedulerTask>) {
        self.scheduler_tasks = tasks;
    }

    fn set_skills(&mut self, skills: Vec<SkillSummary>) {
        self.skills = skills;
    }

    fn set_settings(&mut self, sections: Vec<SettingsSection>, cards: Vec<SettingsCard>) {
        self.settings_sections = sections;
        self.settings_cards = cards;
    }
}

/// How the orb surface composites with whatever is behind its window.
///
/// `Floating` is the product look on every platform today: a transparent window
/// with an alpha-capable surface so the orb floats on the desktop (needs a
/// compositor). `Opaque` is the Linux headless render-proof path (and a safe
/// degrade for uncomposited Linux): a `CompositeAlphaMode::Opaque` surface with
/// an opaque dark clear, so the orb reliably renders real pixels under Xvfb where
/// transparent X11 present is unreliable. macOS always uses `Floating`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum RenderMode {
    Floating,
    Opaque,
}

struct State {
    surface: wgpu::Surface<'static>,
    device: wgpu::Device,
    queue: wgpu::Queue,
    config: wgpu::SurfaceConfiguration,
    render_pipeline: wgpu::RenderPipeline,
    uniform_buffer: wgpu::Buffer,
    uniform_bind_group: wgpu::BindGroup,
    uniforms: Uniforms,
    size: PhysicalSize<u32>,
    start: Instant,
    active: bool,
    target_mode: f32,
    target_warmth: f32,
    target_energy: f32,
    /// Latest voice level from the Swift bridge; None means no live audio,
    /// so the orb falls back to a slow synthetic breath.
    bridge_audio: Option<f32>,
    /// Clear color for the orb pass. Transparent for `Floating`, opaque dark for
    /// `Opaque` so the orb shows against a solid background under Xvfb.
    clear_color: wgpu::Color,
}

/// Voice spine V4: map a raw TTS RMS (`state.audio`) into the orb's expressive
/// audio band. Speech RMS is quiet — peaks ~0.1, mean ~0.03 (measured live) —
/// so passing it through raw rides the orb BELOW its rest breath (~0.12–0.22)
/// and the voice never visibly swells the silhouette. Lift it so pauses sit
/// near the rest level and speech peaks push well above it.
fn rms_to_level(rms: f32) -> f32 {
    // 0.0 rms → 0.18 (≈ rest breath, smooth); 0.12+ rms → 0.60 (full swell).
    let normalized = (rms / 0.12).clamp(0.0, 1.0);
    0.18 + normalized * 0.42
}

/// Voice spine V4: map a parsed `state.audio` patch onto the live level the
/// orb rides. `Set(rms)` lifts the raw RMS into the expressive band (see
/// [`rms_to_level`]); `Clear` returns the orb to its synthetic breath;
/// `Unchanged` is a no-op (so a plain mode command that OMITS `audio` never
/// clobbers an in-progress ride). Pure/free so it is unit-testable without
/// constructing a full `State` (which needs a GPU window).
fn apply_audio_patch(patch: AudioPatch, bridge_audio: &mut Option<f32>) {
    match patch {
        AudioPatch::Unchanged => {}
        AudioPatch::Set(rms) => *bridge_audio = Some(rms_to_level(rms)),
        AudioPatch::Clear => *bridge_audio = None,
    }
}

impl State {
    async fn new(window: &'static Window, mode: RenderMode) -> Result<Self, Box<dyn Error>> {
        let size = window.inner_size();
        let instance = wgpu::Instance::new(wgpu::InstanceDescriptor {
            backends: wgpu::Backends::all(),
            dx12_shader_compiler: wgpu::Dx12Compiler::Fxc,
            flags: wgpu::InstanceFlags::default(),
            gles_minor_version: wgpu::Gles3MinorVersion::Automatic,
        });
        let surface = instance.create_surface(window)?;
        let adapter = instance
            .request_adapter(&wgpu::RequestAdapterOptions {
                power_preference: wgpu::PowerPreference::LowPower,
                compatible_surface: Some(&surface),
                force_fallback_adapter: false,
            })
            .await
            .ok_or("no suitable GPU adapter found")?;
        let (device, queue) = adapter
            .request_device(
                &wgpu::DeviceDescriptor {
                    label: Some("Fae Orb Device"),
                    required_features: wgpu::Features::empty(),
                    required_limits: wgpu::Limits::default(),
                },
                None,
            )
            .await?;

        let surface_caps = surface.get_capabilities(&adapter);
        let format = surface_caps
            .formats
            .iter()
            .copied()
            .find(wgpu::TextureFormat::is_srgb)
            .or_else(|| surface_caps.formats.first().copied())
            .ok_or("surface has no supported formats")?;
        let present_mode = if surface_caps
            .present_modes
            .contains(&wgpu::PresentMode::Mailbox)
        {
            wgpu::PresentMode::Mailbox
        } else {
            wgpu::PresentMode::Fifo
        };
        // Floating wants alpha compositing (orb floats on the desktop); Opaque
        // forces a non-alpha surface so headless X11/Xvfb present is reliable.
        let alpha_mode = match mode {
            RenderMode::Opaque => surface_caps
                .alpha_modes
                .iter()
                .copied()
                .find(|m| *m == wgpu::CompositeAlphaMode::Opaque)
                .or_else(|| surface_caps.alpha_modes.first().copied())
                .ok_or("surface has no supported alpha modes")?,
            RenderMode::Floating => surface_caps
                .alpha_modes
                .iter()
                .copied()
                .find(|m| *m == wgpu::CompositeAlphaMode::PreMultiplied)
                .or_else(|| {
                    surface_caps
                        .alpha_modes
                        .iter()
                        .copied()
                        .find(|m| *m == wgpu::CompositeAlphaMode::PostMultiplied)
                })
                .or_else(|| surface_caps.alpha_modes.first().copied())
                .ok_or("surface has no supported alpha modes")?,
        };
        // Transparent clear lets the desktop show through (Floating); an opaque
        // dark tone (~#16141C) backs the orb when compositing is unavailable.
        let clear_color = match mode {
            RenderMode::Floating => wgpu::Color {
                r: 0.0,
                g: 0.0,
                b: 0.0,
                a: 0.0,
            },
            RenderMode::Opaque => wgpu::Color {
                r: 0.012,
                g: 0.011,
                b: 0.018,
                a: 1.0,
            },
        };
        let config = wgpu::SurfaceConfiguration {
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
            format,
            width: size.width.max(1),
            height: size.height.max(1),
            present_mode,
            alpha_mode,
            view_formats: vec![],
            desired_maximum_frame_latency: 2,
        };
        surface.configure(&device, &config);

        let uniforms = Uniforms::new(size);
        let uniform_buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("Fae Orb Uniform Buffer"),
            contents: bytemuck::bytes_of(&uniforms),
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
        });
        let uniform_bind_group_layout =
            device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
                label: Some("Fae Orb Uniform Bind Group Layout"),
                entries: &[wgpu::BindGroupLayoutEntry {
                    binding: 0,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Buffer {
                        ty: wgpu::BufferBindingType::Uniform,
                        has_dynamic_offset: false,
                        min_binding_size: None,
                    },
                    count: None,
                }],
            });
        let uniform_bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("Fae Orb Uniform Bind Group"),
            layout: &uniform_bind_group_layout,
            entries: &[wgpu::BindGroupEntry {
                binding: 0,
                resource: uniform_buffer.as_entire_binding(),
            }],
        });

        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("Fae Orb WGSL"),
            source: wgpu::ShaderSource::Wgsl(include_str!("orb.wgsl").into()),
        });
        let pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("Fae Orb Pipeline Layout"),
            bind_group_layouts: &[&uniform_bind_group_layout],
            push_constant_ranges: &[],
        });
        let render_pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("Fae Orb Render Pipeline"),
            layout: Some(&pipeline_layout),
            vertex: wgpu::VertexState {
                module: &shader,
                entry_point: "vs_main",
                buffers: &[],
                compilation_options: wgpu::PipelineCompilationOptions::default(),
            },
            fragment: Some(wgpu::FragmentState {
                module: &shader,
                entry_point: "fs_main",
                targets: &[Some(wgpu::ColorTargetState {
                    format,
                    blend: Some(wgpu::BlendState::ALPHA_BLENDING),
                    write_mask: wgpu::ColorWrites::ALL,
                })],
                compilation_options: wgpu::PipelineCompilationOptions::default(),
            }),
            primitive: wgpu::PrimitiveState::default(),
            depth_stencil: None,
            multisample: wgpu::MultisampleState::default(),
            multiview: None,
        });

        Ok(Self {
            surface,
            device,
            queue,
            config,
            render_pipeline,
            uniform_buffer,
            uniform_bind_group,
            uniforms,
            size,
            start: Instant::now(),
            active: true,
            target_mode: 0.0,
            target_warmth: 0.5,
            target_energy: 0.4,
            bridge_audio: None,
            clear_color,
        })
    }

    fn resize(&mut self, size: PhysicalSize<u32>) {
        if size.width == 0 || size.height == 0 {
            return;
        }
        self.size = size;
        self.config.width = size.width;
        self.config.height = size.height;
        self.surface.configure(&self.device, &self.config);
        self.uniforms.resolution = [size.width as f32, size.height as f32];
    }

    fn set_active(&mut self, active: bool) {
        self.active = active;
        self.uniforms.active = if active { 1.0 } else { 0.0 };
        if !active {
            self.uniforms.audio = 0.0;
            self.bridge_audio = None;
        }
    }

    fn toggle_active(&mut self) {
        self.set_active(!self.active);
    }

    fn set_audio(&mut self, patch: AudioPatch) {
        apply_audio_patch(patch, &mut self.bridge_audio);
    }

    fn set_status_progress(&mut self, progress: Option<f32>, visible: bool) {
        self.uniforms.status_progress = progress.unwrap_or(0.0).clamp(0.0, 1.0);
        self.uniforms.status_visible = if visible { 1.0 } else { 0.0 };
    }

    fn set_emotion(&mut self, ui_state: FaeUiState, feeling: Option<&str>) {
        self.target_mode = match ui_state {
            FaeUiState::Quiescent => 0.0,
            FaeUiState::Listening => 1.0,
            FaeUiState::Thinking => 2.0,
            FaeUiState::Speaking => 3.0,
        };
        let (warmth, energy) = feeling_targets(feeling);
        self.target_warmth = warmth;
        self.target_energy = energy;
    }

    fn update(&mut self) {
        let time = self.start.elapsed().as_secs_f32();
        self.uniforms.time = time;
        // Audio drives silhouette and flow, so it must be SMOOTH: live bridge
        // level when present, else a synthetic breath. The old 19 Hz "tremor"
        // jittered the radius every frame and read as jerkiness. Eased, never
        // snapped. The idle orb keeps breathing too — slower and shallower — so
        // it reads as a living presence at rest, never a frozen dead still.
        let target = if self.active {
            let breath = 0.12 + 0.10 * (0.5 + 0.5 * (time * 0.8).sin());
            self.bridge_audio.unwrap_or(breath)
        } else {
            // Calm idle breath: a touch gentler than active, but a full resting
            // baseline (not a dim ember) so the orb returns to its start glow
            // after speaking instead of looking extinguished.
            0.11 + 0.05 * (0.5 + 0.5 * (time * 0.45).sin())
        };
        self.uniforms.audio += (target - self.uniforms.audio) * 0.08;
        // Ease emotion params toward their targets so demeanor shifts read as
        // the fog changing its mind, never as a palette snap (~1s settle). Idle
        // now animates (WaitUntil, not Wait), so easing runs every frame and a
        // frozen mid-transition still can no longer occur.
        let ease = 0.04;
        self.uniforms.mode += (self.target_mode - self.uniforms.mode) * ease;
        self.uniforms.warmth += (self.target_warmth - self.uniforms.warmth) * ease;
        self.uniforms.energy += (self.target_energy - self.uniforms.energy) * ease;
        self.queue
            .write_buffer(&self.uniform_buffer, 0, bytemuck::bytes_of(&self.uniforms));
    }

    fn render(&mut self) -> Result<(), wgpu::SurfaceError> {
        let output = self.surface.get_current_texture()?;
        let view = output
            .texture
            .create_view(&wgpu::TextureViewDescriptor::default());
        let mut encoder = self
            .device
            .create_command_encoder(&wgpu::CommandEncoderDescriptor {
                label: Some("Fae Orb Render Encoder"),
            });
        {
            let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("Fae Orb Render Pass"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &view,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(self.clear_color),
                        store: wgpu::StoreOp::Store,
                    },
                })],
                depth_stencil_attachment: None,
                timestamp_writes: None,
                occlusion_query_set: None,
            });
            pass.set_pipeline(&self.render_pipeline);
            pass.set_bind_group(0, &self.uniform_bind_group, &[]);
            pass.draw(0..3, 0..1);
        }
        self.queue.submit([encoder.finish()]);
        output.present();
        Ok(())
    }
}

fn main() -> Result<(), Box<dyn Error>> {
    env_logger::init();
    if std::env::args().any(|arg| arg == "--smoke-settings-panel") {
        return run_settings_panel_smoke();
    }
    if std::env::args().any(|arg| arg == "--smoke-pill") {
        return run_pill_smoke();
    }

    let mut event_loop_builder = EventLoopBuilder::<UserEvent>::with_user_event();
    #[allow(unused_mut)]
    let mut event_loop = event_loop_builder.build();
    // The orb host is part of Fae, not a second app: no Dock icon, no app
    // menu, no Cmd+Q identity of its own. Quit flows through the Swift host.
    #[cfg(target_os = "macos")]
    {
        use tao::platform::macos::{ActivationPolicy, EventLoopExtMacOS};
        event_loop.set_activation_policy(ActivationPolicy::Accessory);
        // Install a minimal app menu (Edit → Cut/Copy/Paste/Select All) so the
        // standard editing key equivalents reach the focused WKWebView (the pill
        // composer). As an Accessory app the orb host has no visible menubar; on
        // macOS ⌘V into a WKWebView text field is routed through the Edit→Paste
        // menu item, so with no main-menu Edit item the keystroke never reaches
        // the pill and paste is dead. This registers the key equivalents without
        // showing a menubar or adding a Dock icon. See `install_edit_menubar`.
        if let Err(error) = install_edit_menubar() {
            log::warn!("failed to install edit menu (⌘V may not paste into the pill): {error}");
        }
    }
    let proxy = event_loop.create_proxy();
    let menu_proxy = proxy.clone();
    let panel_proxy = proxy.clone();
    muda::MenuEvent::set_event_handler(Some(move |event| {
        if let Err(error) = menu_proxy.send_event(UserEvent::Menu(event)) {
            log::warn!("failed to forward menu event: {error}");
        }
    }));
    spawn_stdin_bridge(proxy.clone());
    // Orb-host-owns-state: spawn the direct daemon subscription. The bridge
    // derives the orb mode (thinking/speaking/idle via grace-hold) from
    // `assistant.generating` + `audio.level` + `audio.playback_ended`, and
    // rides the voice RMS. Default ON; FAE_ORB_DAEMON_AUDIO=0 disables.
    #[cfg(unix)]
    daemon_audio_bridge::spawn_daemon_bridge(proxy.clone());

    let window = WindowBuilder::new()
        .with_title("Fae Orb")
        .with_inner_size(PhysicalSize::new(420, 420))
        .with_resizable(false)
        .with_decorations(false)
        .with_transparent(true)
        .with_always_on_top(true)
        .build(&event_loop)?;
    // wgpu 0.20 ties `Surface<'static>` to a window that must outlive the surface.
    // This shell exits as a process, so leaking the single orb window is acceptable
    // and avoids unsafe lifetime juggling around the OS window handle.
    let window: &'static Window = Box::leak(Box::new(window));
    // Read orb-menu config from env vars set by RustUiShellController at launch.
    // `advanced`: FAE_ORB_ADVANCED_MENUS=1 reveals the engineering section.
    // `fleet`:    FAE_ORB_FLEET=<agentId1>,<agentId2> builds the Hand-off submenu.
    // Both apply at next launch after the user changes the Settings toggle.
    let orb_advanced = std::env::var("FAE_ORB_ADVANCED_MENUS").ok().as_deref() == Some("1");
    let orb_fleet: Vec<String> = std::env::var("FAE_ORB_FLEET")
        .unwrap_or_default()
        .split(',')
        .filter(|s| !s.is_empty())
        .map(String::from)
        .collect();
    let orb_menu = OrbMenu::new(orb_advanced, &orb_fleet)?;
    let mut state = pollster::block_on(State::new(window, RenderMode::Floating))?;
    let mut orb_ui = OrbUiModel::new();
    let mut cursor_position = PhysicalPosition::new(210.0, 210.0);
    let mut web_panels: Vec<WebPanel> = Vec::new();
    let mut pill = open_pill_panel(&event_loop, &panel_proxy)?;
    position_pill(window, &pill);
    let mut last_pill: Option<(String, String)> = None;
    // When Fae entered thinking mode — drives the pill's elapsed counter so
    // long turns (NaN retries can take 30s+) read as progress, not a hang.
    let mut thinking_since: Option<Instant> = None;
    // Orb-host-owns-state: the grace-hold state machine driven by daemon events
    // (assistant.generating / audio.level / playback_ended). Derives the orb
    // mode WITHOUT the thinking→idle→thinking / speaking→idle→speaking flicker.
    let mut orb_state_machine = orb_state::OrbStateMachine::new();
    // Stable epoch for the state machine's `now_ms` clock (monotonic).
    let process_start = Instant::now();
    // Last OrbUiState we applied from the state machine — lets us skip redundant
    // set_active/set_emotion/orb_ui writes when the mode is unchanged.
    let mut last_applied_mode: Option<orb_state::OrbMode> = None;
    // Orb long-press gesture (owner design, touch-friendly): press-and-HOLD
    // starts capture (release sends); moving past the slop before the hold
    // fires means the user is dragging the orb, not talking.
    let mut press = PressState::Idle;
    push_pill_messages(&pill, &orb_ui);
    refresh_pill(&pill, &orb_ui, None, &mut last_pill);

    event_loop.run(move |event, target, control_flow| {
        // Active turns and a pending long-press render flat-out (Poll). When
        // idle the orb still breathes, but at a capped ~30 fps via WaitUntil so
        // the living-presence fog sips battery instead of busy-rendering — and
        // never freezes on a dead still the way ControlFlow::Wait did.
        *control_flow = if state.active || matches!(press, PressState::Pending { .. }) {
            ControlFlow::Poll
        } else {
            ControlFlow::WaitUntil(Instant::now() + IDLE_FRAME_INTERVAL)
        };

        // Long-press timer: a stationary press that survives the hold
        // threshold becomes push-to-talk; the Swift host starts capture.
        if let PressState::Pending { at, .. } = press {
            if at.elapsed().as_millis() >= LONG_PRESS_MS {
                press = PressState::Talking;
                eprintln!("[gesture] long-press hold fired → talk_start");
                emit_menu_action(MenuAction::TalkStart);
            }
        }

        match event {
            Event::UserEvent(UserEvent::Menu(event)) => {
                if let Some(action) = OrbMenu::action_for_event(&event) {
                    emit_menu_action(action);
                    handle_menu_action(action, target, &orb_ui, &mut web_panels, &panel_proxy);
                    window.request_redraw();
                } else {
                    // Dynamic items (e.g. handoff_<agentId>) bypass MenuAction —
                    // emit the raw menu ID so Swift can dispatch them.
                    let raw_id = event.id().as_ref();
                    if !raw_id.is_empty() {
                        emit_raw_menu_action(raw_id);
                        window.request_redraw();
                    }
                }
            }
            // UX W1: a `request_input` command drives the pill's composer
            // directly (expand + prompted/masked mode) — it needs `pill`, which
            // `apply_bridge_command` cannot see, so intercept it here.
            Event::UserEvent(UserEvent::Bridge(ShellCommand::RequestInput {
                request_id,
                prompt,
                secure,
                multiline,
                placeholder,
            })) => {
                window.set_visible(true);
                pill_request_input(
                    &mut pill,
                    window,
                    request_id,
                    &prompt,
                    secure,
                    multiline,
                    placeholder.as_deref(),
                );
                window.request_redraw();
            }
            // UX auto-cancel: Swift saw a new turn start while a `request_input`
            // was still outstanding, so it asks the pill to leave request-input
            // mode. Collapsing runs `__faeExpand(false)`, whose JS calls
            // `exitRequestMode()` — restoring the normal composer and, crucially,
            // shrinking the pill window so its webview stops capturing clicks over
            // the orb. Idempotent: a no-op when no request is pending.
            Event::UserEvent(UserEvent::Bridge(ShellCommand::CancelInput)) => {
                if pill.pending_input.take().is_some() {
                    set_pill_expanded(&mut pill, window, false);
                }
                window.request_redraw();
            }
            Event::UserEvent(UserEvent::Bridge(command)) => {
                apply_bridge_command(
                    command,
                    &mut state,
                    &mut orb_ui,
                    window,
                    &mut web_panels,
                    control_flow,
                );
                // The pill mirrors the orb's visibility and narrates its state.
                if orb_ui.ui_mode == FaeUiState::Thinking {
                    if thinking_since.is_none() {
                        thinking_since = Some(Instant::now());
                    }
                } else {
                    thinking_since = None;
                }
                pill.window.set_visible(window.is_visible());
                // Conversation/ClearConversation update the message list; pushing
                // every bridge command is idempotent and keeps the pill's latest
                // line and expanded log in sync without a special-case match.
                push_pill_messages(&pill, &orb_ui);
                refresh_pill(
                    &pill,
                    &orb_ui,
                    thinking_since.map(|since| since.elapsed().as_secs()),
                    &mut last_pill,
                );
                window.request_redraw();
            }
            Event::UserEvent(UserEvent::PanelAction(action_json)) => {
                // The pill drives expand/collapse locally (window resize); all
                // other panel actions (send_text, set_access, …) forward to Swift.
                let parsed = serde_json::from_str::<serde_json::Value>(&action_json).ok();
                let kind = parsed
                    .as_ref()
                    .and_then(|value| value.get("type"))
                    .and_then(|kind| kind.as_str());
                match kind {
                    Some("pill_expand") => set_pill_expanded(&mut pill, window, true),
                    Some("pill_collapse") => set_pill_expanded(&mut pill, window, false),
                    Some("info_action") => {
                        // The user clicked the info indicator. Route by the
                        // canonical item from our model (don't trust the JS id
                        // alone — look it up so kind/action are authoritative).
                        let id = parsed
                            .as_ref()
                            .and_then(|v| v.get("id"))
                            .and_then(|v| v.as_str())
                            .map(str::to_owned);
                        handle_info_action(id.as_deref(), &orb_ui);
                    }
                    // The collapsed pill grows to fit a wrapped response (and
                    // shrinks back for a one-line status/hint). Ignored while
                    // expanded — the conversation panel owns the size there.
                    Some("pill_resize") => {
                        if !pill.expanded {
                            if let Some(height) = parsed
                                .as_ref()
                                .and_then(|value| value.get("height"))
                                .and_then(serde_json::Value::as_u64)
                            {
                                // Cap generously so a longer reply stays readable
                                // in the collapsed caption; beyond the cap the
                                // caption text scrolls internally (see PILL_HTML).
                                let height = (height as u32).clamp(52, 320);
                                if height != pill.last_collapsed_height {
                                    pill.last_collapsed_height = height;
                                    pill.window.set_inner_size(LogicalSize::new(
                                        COLLAPSED_PILL.width,
                                        height,
                                    ));
                                    position_pill(window, &pill);
                                }
                            }
                        }
                    }
                    // UX W1: the pill answered (or cancelled) a Swift
                    // `request_input`. Clear the guard, collapse back to the
                    // caption, and forward the event to Swift, whose
                    // InputRequestBridge resolves the suspended continuation.
                    Some("input_response") | Some("input_cancel") => {
                        pill.pending_input = None;
                        set_pill_expanded(&mut pill, window, false);
                        emit_panel_action(&action_json);
                    }
                    _ => emit_panel_action(&action_json),
                }
            }
            // Orb-host-owns-state: a daemon-originated event. Apply the audio
            // side-band (ride the voice) AND run the grace-hold state machine
            // to derive the orb mode (thinking/speaking/idle WITHOUT the
            // mid-turn flicker). The state machine is the single source of
            // truth for the mode now — Swift no longer drives it.
            #[cfg(unix)]
            Event::UserEvent(UserEvent::DaemonOrb(event)) => {
                use orb_state::OrbDaemonEvent;
                // Audio side-band: ride the RMS while speaking, clear on end/reset.
                match &event {
                    OrbDaemonEvent::AudioLevel(rms) => {
                        state.set_audio(AudioPatch::Set(*rms));
                    }
                    OrbDaemonEvent::PlaybackEnded
                    | OrbDaemonEvent::ConnectionReset
                    | OrbDaemonEvent::Generating(false) => {
                        state.set_audio(AudioPatch::Clear);
                    }
                    _ => {}
                }
                // Run the grace-hold state machine on the mode-relevant inputs.
                let now_ms = process_start.elapsed().as_millis();
                if let Some(input) = event.to_state_input() {
                    let mode = orb_state_machine.event(input, now_ms);
                    apply_orb_mode(
                        mode,
                        &mut orb_ui,
                        &mut state,
                        &mut last_applied_mode,
                        &mut thinking_since,
                    );
                }
                // Forward info updates to the pill model (Step 3: the indicator).
                if let OrbDaemonEvent::InfoUpdate(items) = &event {
                    orb_ui.info_items = items.clone();
                    push_pill_messages(&pill, &orb_ui);
                    push_pill_info(&pill, &orb_ui);
                    refresh_pill(
                        &pill,
                        &orb_ui,
                        thinking_since.map(|since| since.elapsed().as_secs()),
                        &mut last_pill,
                    );
                }
                window.request_redraw();
            }
            Event::WindowEvent {
                event, window_id, ..
            } if window_id == window.id() => match event {
                WindowEvent::CloseRequested => {
                    // Closing the orb means quitting Fae: tell the Swift host
                    // so the whole app exits — never leave Fae running
                    // invisibly with no UI to quit from.
                    emit_menu_action(MenuAction::Quit);
                    *control_flow = ControlFlow::Exit;
                }
                WindowEvent::Resized(size) => {
                    state.resize(size);
                    window.request_redraw();
                }
                WindowEvent::CursorMoved { position, .. } => {
                    cursor_position = position;
                    if let PressState::Pending { origin, .. } = press {
                        let dx = position.x - origin.x;
                        let dy = position.y - origin.y;
                        if (dx * dx + dy * dy).sqrt() > PRESS_SLOP_PX {
                            // Moved before the hold fired: this is a drag.
                            press = PressState::Idle;
                            if let Err(error) = window.drag_window() {
                                log::warn!("failed to start orb drag: {error}");
                            }
                        }
                    }
                }
                WindowEvent::Moved(_) => {
                    position_pill(window, &pill);
                }
                WindowEvent::KeyboardInput {
                    event:
                        KeyEvent {
                            physical_key: KeyCode::Space,
                            state: ElementState::Pressed,
                            ..
                        },
                    ..
                } => {
                    state.toggle_active();
                    window.request_redraw();
                }
                WindowEvent::MouseInput {
                    state: ElementState::Pressed,
                    button: MouseButton::Right,
                    ..
                } => {
                    show_context_menu(&orb_menu, window, cursor_position);
                }
                WindowEvent::MouseInput {
                    state: ElementState::Pressed,
                    button: MouseButton::Left,
                    ..
                } => {
                    // Press intent is decided by what happens next: hold still
                    // ≥ LONG_PRESS_MS → talk; move first → drag. (The pill is the
                    // conversation surface now — the orb has no click target.)
                    press = PressState::Pending {
                        at: Instant::now(),
                        origin: cursor_position,
                    };
                }
                WindowEvent::MouseInput {
                    state: ElementState::Released,
                    button: MouseButton::Left,
                    ..
                } => match press {
                    PressState::Talking => {
                        // Long-press release = send (mirrors the ⌥ gesture).
                        press = PressState::Idle;
                        eprintln!("[gesture] long-press release → talk_stop");
                        emit_menu_action(MenuAction::TalkStop);
                    }
                    PressState::Pending { .. } => {
                        // A short stationary click normally does nothing: the orb
                        // is drag-only (move it), long-press to talk, right-click
                        // for the menu. The one exception is an outstanding pill
                        // `request_input` — a short click on the orb cancels it
                        // (frees the Swift continuation and collapses the pill) so
                        // an abandoned card can never trap the pointer.
                        press = PressState::Idle;
                        if let Some(request_id) = pill.pending_input.take() {
                            let cancel = serde_json::json!({
                                "type": "input_cancel",
                                "request_id": request_id,
                            });
                            emit_panel_action(&cancel.to_string());
                            set_pill_expanded(&mut pill, window, false);
                        }
                    }
                    PressState::Idle => {}
                },
                _ => {}
            },
            Event::WindowEvent {
                event, window_id, ..
            } => {
                if window_id == pill.window.id() {
                    // Click-away / focus to another window collapses the pill
                    // back to its single-line caption. If a Swift `request_input`
                    // is pending (UX W1), a click-away is a cancel — emit it so
                    // the suspended continuation is freed rather than left to
                    // time out.
                    if matches!(event, WindowEvent::Focused(false)) && pill.expanded {
                        if let Some(request_id) = pill.pending_input.take() {
                            let cancel = serde_json::json!({
                                "type": "input_cancel",
                                "request_id": request_id,
                            });
                            emit_panel_action(&cancel.to_string());
                        }
                        set_pill_expanded(&mut pill, window, false);
                    }
                } else if matches!(event, WindowEvent::CloseRequested) {
                    web_panels.retain(|panel| panel.window.id() != window_id);
                }
            }
            Event::RedrawRequested(window_id) if window_id == window.id() => {
                state.update();
                match state.render() {
                    Ok(()) => {}
                    Err(wgpu::SurfaceError::Lost | wgpu::SurfaceError::Outdated) => {
                        state.resize(state.size);
                    }
                    Err(wgpu::SurfaceError::OutOfMemory) => *control_flow = ControlFlow::Exit,
                    Err(wgpu::SurfaceError::Timeout) => {
                        log::warn!("surface timeout while rendering orb");
                    }
                }
            }
            Event::MainEventsCleared => {
                // Orb-host-owns-state: tick the grace-hold state machine so an
                // expired grace (assistant stopped, audio gone) returns the orb
                // to idle without waiting for the next daemon event.
                let now_ms = process_start.elapsed().as_millis();
                let mode = orb_state_machine.tick(now_ms);
                apply_orb_mode(
                    mode,
                    &mut orb_ui,
                    &mut state,
                    &mut last_applied_mode,
                    &mut thinking_since,
                );
                // Tick the thinking counter once a second (refresh_pill dedupes
                // by content, so per-frame calls only repaint on text change).
                if thinking_since.is_some() {
                    refresh_pill(
                        &pill,
                        &orb_ui,
                        thinking_since.map(|since| since.elapsed().as_secs()),
                        &mut last_pill,
                    );
                }
                // Drive a frame on every pass — when active/pending this is
                // continuous (Poll); when idle it fires once per WaitUntil tick,
                // keeping the breathing fog alive at the capped idle rate.
                window.request_redraw();
            }
            _ => {}
        }
    });
}

fn run_settings_panel_smoke() -> Result<(), Box<dyn Error>> {
    let event_loop = EventLoopBuilder::<UserEvent>::with_user_event().build();
    let proxy = event_loop.create_proxy();
    let panel_proxy = proxy.clone();
    let exit_proxy = proxy.clone();
    thread::spawn(move || {
        thread::sleep(Duration::from_secs(10));
        let _ = exit_proxy.send_event(UserEvent::Bridge(ShellCommand::Quit));
    });

    let mut orb_ui = OrbUiModel::new();
    orb_ui.set_settings(smoke_settings_sections(), smoke_settings_cards());
    let mut web_panels = Vec::new();
    let mut opened = false;

    event_loop.run(move |event, target, control_flow| {
        *control_flow = ControlFlow::Poll;
        match event {
            Event::NewEvents(StartCause::Init) if !opened => {
                opened = true;
                match open_settings_panel(target, &orb_ui, &panel_proxy) {
                    Ok(panel) => {
                        log::info!("smoke settings panel opened");
                        web_panels.push(panel);
                    }
                    Err(error) => {
                        log::error!("failed to open smoke settings panel: {error}");
                        *control_flow = ControlFlow::Exit;
                    }
                }
            }
            Event::UserEvent(UserEvent::Bridge(ShellCommand::Quit)) => {
                log::info!("smoke settings panel exit");
                *control_flow = ControlFlow::Exit;
            }
            Event::WindowEvent {
                event: WindowEvent::CloseRequested,
                ..
            } => {
                *control_flow = ControlFlow::Exit;
            }
            _ => {}
        }
    });
}

/// Headless render proof for the orb + pill (P6/D1). Opens the wgpu orb in
/// `RenderMode::Opaque` and the (Linux-opaque) pill at fixed, non-overlapping
/// positions, seeds sample messages so the pill paints, renders orb frames, then
/// exits 0. CI captures the Xvfb root and asserts each surface region rendered
/// real pixels (per-surface crop color counts). Exits cleanly on macOS too.
fn run_pill_smoke() -> Result<(), Box<dyn Error>> {
    let event_loop = EventLoopBuilder::<UserEvent>::with_user_event().build();
    let proxy = event_loop.create_proxy();
    let panel_proxy = proxy.clone();
    let exit_proxy = proxy.clone();
    thread::spawn(move || {
        thread::sleep(Duration::from_secs(10));
        let _ = exit_proxy.send_event(UserEvent::Bridge(ShellCommand::Quit));
    });

    let mut orb_ui = OrbUiModel::new();
    orb_ui.push_message("you".to_string(), "Good morning, Fae.".to_string());
    orb_ui.push_message(
        "fae".to_string(),
        "Good morning — your 9am moved to 10.".to_string(),
    );
    orb_ui.push_message("you".to_string(), "Thanks.".to_string());

    let mut state: Option<State> = None;
    // Held in a Vec (like the settings smoke) purely to keep the pill window +
    // webview alive for the run without tripping unused-assignment lints.
    let mut pills: Vec<PillPanel> = Vec::new();
    let mut opened = false;

    event_loop.run(move |event, target, control_flow| {
        *control_flow = ControlFlow::Poll;
        match event {
            Event::NewEvents(StartCause::Init) if !opened => {
                opened = true;
                // Orb at a fixed top-left rect; pill clear of it — so CI can crop
                // and assert each surface independently.
                let window = match WindowBuilder::new()
                    .with_title("Fae Orb")
                    .with_inner_size(PhysicalSize::new(420, 420))
                    .with_position(LogicalPosition::new(40.0, 40.0))
                    .with_resizable(false)
                    .with_decorations(false)
                    .with_transparent(false)
                    .build(target)
                {
                    Ok(w) => w,
                    Err(error) => {
                        log::error!("smoke orb window failed: {error}");
                        *control_flow = ControlFlow::Exit;
                        return;
                    }
                };
                let window: &'static Window = Box::leak(Box::new(window));
                match pollster::block_on(State::new(window, RenderMode::Opaque)) {
                    Ok(mut s) => {
                        s.set_active(true);
                        state = Some(s);
                        log::info!("smoke orb opened (opaque)");
                    }
                    Err(error) => {
                        log::error!("smoke orb state failed: {error}");
                        *control_flow = ControlFlow::Exit;
                        return;
                    }
                }
                match open_pill_panel(target, &panel_proxy) {
                    Ok(p) => {
                        p.window
                            .set_outer_position(LogicalPosition::new(500.0, 120.0));
                        // __faeSetMessages adds `.show`, so this also makes the
                        // collapsed pill visible (paints the caption + accent dot).
                        push_pill_messages(&p, &orb_ui);
                        pills.push(p);
                        log::info!("smoke pill opened");
                    }
                    Err(error) => {
                        log::error!("smoke pill failed: {error}");
                        *control_flow = ControlFlow::Exit;
                    }
                }
            }
            Event::MainEventsCleared => {
                if let Some(s) = state.as_mut() {
                    s.update();
                    if let Err(error) = s.render() {
                        log::warn!("smoke orb render: {error}");
                    }
                }
            }
            Event::UserEvent(UserEvent::Bridge(ShellCommand::Quit)) => {
                log::info!("smoke pill exit");
                *control_flow = ControlFlow::Exit;
            }
            Event::WindowEvent {
                event: WindowEvent::CloseRequested,
                ..
            } => {
                *control_flow = ControlFlow::Exit;
            }
            _ => {}
        }
    });
}

fn smoke_settings_sections() -> Vec<SettingsSection> {
    vec![SettingsSection {
        id: "voice".to_string(),
        title: "Voice".to_string(),
        description: Some("Opaque WebKitGTK smoke controls for Linux rendering.".to_string()),
        settings: vec![
            SettingItem {
                key: "tts.speed".to_string(),
                title: "Playback speed".to_string(),
                description: "Adjust how quickly Fae speaks.".to_string(),
                kind: "number".to_string(),
                value: "1.10".to_string(),
                options: None,
                min: Some("0.7".to_string()),
                max: Some("1.4".to_string()),
                step: Some("0.05".to_string()),
                unit: Some("multiplier".to_string()),
                read_only: Some(false),
            },
            SettingItem {
                key: "llm.thinking_level".to_string(),
                title: "Thinking depth".to_string(),
                description: "Reasoning budget for future turns.".to_string(),
                kind: "select".to_string(),
                value: "fast".to_string(),
                options: Some(vec![
                    SettingOption {
                        value: "fast".to_string(),
                        label: "Fast".to_string(),
                    },
                    SettingOption {
                        value: "deep".to_string(),
                        label: "Deep".to_string(),
                    },
                ]),
                min: None,
                max: None,
                step: None,
                unit: None,
                read_only: Some(false),
            },
        ],
    }]
}

fn smoke_settings_cards() -> Vec<SettingsCard> {
    vec![SettingsCard {
        title: "Opaque fallback".to_string(),
        body:
            "This card validates the Settings panel on WebKitGTK without relying on transparency."
                .to_string(),
        detail: Some(
            "The pill may still show compositor-specific transparency artifacts.".to_string(),
        ),
    }]
}

fn spawn_stdin_bridge(proxy: tao::event_loop::EventLoopProxy<UserEvent>) {
    thread::spawn(move || {
        let stdin = io::stdin();
        for line in stdin.lock().lines() {
            match line {
                Ok(line) if line.trim().is_empty() => {}
                Ok(line) => match serde_json::from_str::<ShellCommand>(&line) {
                    Ok(command) => {
                        if let Err(error) = proxy.send_event(UserEvent::Bridge(command)) {
                            log::warn!("failed to forward bridge command: {error}");
                            break;
                        }
                    }
                    Err(error) => {
                        log::warn!("invalid bridge command JSONL: {error}; line={line:?}")
                    }
                },
                Err(error) => {
                    log::warn!("failed to read bridge stdin: {error}");
                    break;
                }
            }
        }
        // Stdin EOF or error means the Swift host is gone (including hard
        // exits that bypass child cleanup). Never outlive the parent as an
        // orphaned orb — ask the event loop to quit.
        log::info!("bridge stdin closed; requesting orb host shutdown");
        let _ = proxy.send_event(UserEvent::Bridge(ShellCommand::Quit));
    });
}

fn emit_menu_action(action: MenuAction) {
    match protocol::encode_menu_action(action) {
        Ok(line) => {
            let mut stdout = io::stdout().lock();
            if let Err(error) = writeln!(stdout, "{line}") {
                log::warn!("failed to write menu action to stdout: {error}");
            }
        }
        Err(error) => log::warn!("failed to encode menu action: {error}"),
    }
}

/// Emit a dynamic menu action ID (e.g. `handoff_<agentId>`) that doesn't map
/// to a `MenuAction` variant. Uses the same `{"type":"menu","action":"…"}` wire
/// format as `emit_menu_action` so the Swift host handles it identically.
fn emit_raw_menu_action(id: &str) {
    let line = serde_json::json!({"type": "menu", "action": id}).to_string();
    let mut stdout = io::stdout().lock();
    if let Err(error) = writeln!(stdout, "{line}") {
        log::warn!("failed to write raw menu action to stdout: {error}");
    }
}

/// Push the daemon info-indicator set into the pill (the second line: green
/// dot + summary). Called on `OrbDaemonEvent::InfoUpdate`.
fn push_pill_info(pill: &PillPanel, orb_ui: &OrbUiModel) {
    let payload: Vec<serde_json::Value> = orb_ui
        .info_items
        .items
        .iter()
        .map(|item| serde_json::json!({ "id": item.id, "kind": item.kind, "title": item.title }))
        .collect();
    let json = serde_json::to_string(&payload).unwrap_or_else(|_| "[]".to_string());
    if let Err(error) = pill
        .webview
        .evaluate_script(&format!("window.__faeSetInfoItems({json});"))
    {
        log::warn!("failed to push pill info: {error}");
    }
}
/// Orb-host-owns-state: apply a derived [`OrbMode`] to the orb + pill model.
/// No-op when the mode is unchanged (the grace-hold re-arms frequently during
/// a turn but the effective mode is stable — skip redundant writes). Mirrors
/// what the Swift `State` command used to do, now driven from daemon events.
fn apply_orb_mode(
    mode: orb_state::OrbMode,
    orb_ui: &mut OrbUiModel,
    state: &mut State,
    last_applied: &mut Option<orb_state::OrbMode>,
    thinking_since: &mut Option<Instant>,
) {
    if *last_applied == Some(mode) {
        return;
    }
    *last_applied = Some(mode);
    // Low-noise mode-transition trace for live verification (the orb-host-
    // owns-state flicker check). Emits only on CHANGE, so a steady turn is a
    // handful of lines. Grep `ORB_MODE` to capture the sequence and confirm
    // there are no thinking→idle→thinking / speaking→idle→speaking flips.
    log::info!("ORB_MODE -> {:?}", mode);
    let ui_state = match mode {
        orb_state::OrbMode::Quiescent => FaeUiState::Quiescent,
        orb_state::OrbMode::Thinking => FaeUiState::Thinking,
        orb_state::OrbMode::Speaking => FaeUiState::Speaking,
    };
    orb_ui.ui_mode = ui_state;
    let active = matches!(
        ui_state,
        FaeUiState::Thinking | FaeUiState::Speaking | FaeUiState::Listening
    );
    state.set_active(active);
    state.set_emotion(ui_state, None);
    // Track thinking-entry for the pill's elapsed counter (long turns read as
    // progress, not a hang).
    *thinking_since = if ui_state == FaeUiState::Thinking {
        Some(Instant::now())
    } else {
        None
    };
}

fn emit_panel_action(action_json: &str) {
    let mut stdout = io::stdout().lock();
    if let Err(error) = writeln!(stdout, "{action_json}") {
        log::warn!("failed to write panel action to stdout: {error}");
    }
}

/// Orb-host-owns-state (Step 3): route an info-indicator click by `kind`.
/// Looks the item up in the canonical model (JS sends only the `id`).
fn handle_info_action(id: Option<&str>, orb_ui: &OrbUiModel) {
    let Some(id) = id else {
        log::warn!("info_action: no id in payload");
        return;
    };
    let Some(item) = orb_ui.info_items.items.iter().find(|i| i.id == id) else {
        log::warn!("info_action: unknown id {id:?}");
        return;
    };
    let payload = item.action.as_deref().unwrap_or(&item.id);
    match item.kind.as_str() {
        "url" => {
            if is_openable_url(payload) {
                open_external(payload);
            } else {
                log::warn!("info_action url: refusing payload {payload:?}");
            }
        }
        "app" => open_app(payload, &item.title),
        "research" | "x0x" => open_research_page(&item.title, payload),
        other => log::warn!("info_action: unknown kind {other:?} for id {id:?}"),
    }
}

fn is_openable_url(s: &str) -> bool {
    s.starts_with("https://") || s.starts_with("http://") || s.starts_with("file://")
}

fn open_external(target: &str) {
    let prog = if cfg!(target_os = "macos") {
        "open"
    } else {
        "xdg-open"
    };
    match std::process::Command::new(prog).arg(target).spawn() {
        Ok(_) => log::info!("info_action: opened {target:?} via {prog}"),
        Err(e) => log::warn!("info_action: {prog} {target:?} failed: {e}"),
    }
}

fn open_app(action_or_name: &str, title_fallback: &str) {
    let name = if action_or_name.is_empty() {
        title_fallback
    } else {
        action_or_name
    };
    if cfg!(target_os = "macos") {
        match std::process::Command::new("open")
            .args(["-a", name])
            .spawn()
        {
            Ok(_) => log::info!("info_action: opened app {name:?}"),
            Err(e) => log::warn!("info_action: open -a {name:?} failed: {e}"),
        }
    } else {
        open_external(name);
    }
}

fn open_research_page(title: &str, payload: &str) {
    let body = if is_openable_url(payload) {
        format!(
            "<h1>{}</h1><p><a href=\"{}\">{}</a></p>",
            html_escape(title),
            html_escape(payload),
            html_escape(payload)
        )
    } else {
        format!(
            "<h1>{}</h1><pre>{}</pre>",
            html_escape(title),
            html_escape(payload)
        )
    };
    let html = format!(
        "<!doctype html><meta charset=\"utf-8\"><body style=\"font-family:-apple-system,sans-serif;max-width:680px;margin:40px auto;padding:0 16px\">{}",
        body
    );
    let mut path = std::env::temp_dir();
    path.push(format!("fae-info-{}.html", short_hash(title)));
    if let Err(e) = std::fs::write(&path, &html) {
        log::warn!("info_action: failed to write research page {:?}: {e}", path);
        return;
    }
    open_external(&path_to_file_url(&path));
}

fn short_hash(s: &str) -> String {
    let mut h: u64 = 0xCBF2_9CE4_8422_2325;
    for &b in s.as_bytes() {
        h ^= u64::from(b);
        h = h.wrapping_mul(0x0100_0000_01B3);
    }
    format!("{:x}", h & 0xFFFF_FFFF)
}

fn path_to_file_url(path: &std::path::Path) -> String {
    let s = path.to_string_lossy().replace(' ', "%20");
    if s.starts_with('/') {
        format!("file://{s}")
    } else {
        format!("file:///{s}")
    }
}

fn apply_bridge_command(
    command: ShellCommand,
    state: &mut State,
    orb_ui: &mut OrbUiModel,
    window: &Window,
    web_panels: &mut [WebPanel],
    control_flow: &mut ControlFlow,
) {
    match command {
        ShellCommand::State {
            state: ui_state,
            audio,
            feeling,
        } => {
            // S18: the orb is Fae's only UI and the push-to-talk button — it
            // stays visible at all times; thinking/speaking/listening animate
            // it. Hiding flows through the explicit Hide command (Hide Fae).
            // An audio-only frame (`state` absent, voice spine V4 level push)
            // leaves the mode untouched and only updates the live level.
            if let Some(ui_state) = ui_state {
                let active = matches!(
                    ui_state,
                    FaeUiState::Thinking | FaeUiState::Speaking | FaeUiState::Listening
                );
                orb_ui.ui_mode = ui_state;
                state.set_active(active);
                state.set_emotion(ui_state, feeling.as_deref());
                state.set_status_progress(None, false);
                window.set_visible(true);
            }
            state.set_audio(audio);
        }
        ShellCommand::Status {
            phase,
            message,
            progress,
        } => {
            let should_show = !matches!(phase.as_str(), "running" | "stopped");
            orb_ui.set_status(phase, message, progress);
            state.set_active(should_show);
            state.set_status_progress(orb_ui.status_progress, should_show);
            if let Some(progress) = orb_ui.status_progress {
                state.set_audio(AudioPatch::Set(progress));
            }
            // Status changes animate the orb but never hide it (S18: the orb
            // is the talk button and must stay clickable while idle).
            window.set_visible(true);
        }
        ShellCommand::Conversation { role, text } => {
            // The pill (the conversation surface) is refreshed by the event
            // loop after this command via push_pill_messages.
            orb_ui.push_message(role, text);
        }
        ShellCommand::ConversationStream { text } => {
            orb_ui.set_streaming_text(text);
        }
        ShellCommand::ClearConversation => {
            orb_ui.clear_messages();
        }
        ShellCommand::VoiceMute { muted } => {
            // Store on the model; the pill glyph is refreshed by
            // push_pill_messages after this command returns.
            orb_ui.set_voice_muted(muted);
        }
        ShellCommand::SchedulerSnapshot { tasks } => {
            orb_ui.set_scheduler_tasks(tasks);
            refresh_scheduler_panels(web_panels, orb_ui);
        }
        ShellCommand::SkillsSnapshot { skills } => {
            orb_ui.set_skills(skills);
            refresh_skills_panels(web_panels, orb_ui);
        }
        ShellCommand::ControlsSnapshot => {
            // The access/thinking controls lived in the deleted Messages panel.
            // Swift still emits the snapshot; the orb host no longer renders it.
        }
        ShellCommand::SettingsSnapshot { sections, cards } => {
            orb_ui.set_settings(sections, cards);
            refresh_settings_panels(web_panels, orb_ui);
        }
        ShellCommand::Show => {
            state.set_active(true);
            window.set_visible(true);
        }
        ShellCommand::Hide => {
            state.set_active(false);
            window.set_visible(false);
        }
        ShellCommand::RequestInput { .. } => {
            // UX W1: intercepted in the event loop (it drives the pill directly
            // and needs `pill`, which this function can't see). Reaching here
            // means the interceptor was bypassed — ignore rather than panic.
            log::warn!("request_input reached apply_bridge_command; ignoring");
        }
        ShellCommand::CancelInput => {
            // Intercepted in the event loop (it drives the pill directly and
            // needs `pill`). Reaching here means the interceptor was bypassed.
            log::warn!("cancel_input reached apply_bridge_command; ignoring");
        }
        ShellCommand::Quit => {
            *control_flow = ControlFlow::Exit;
            return;
        }
    }
    *control_flow = if state.active {
        ControlFlow::Poll
    } else {
        ControlFlow::Wait
    };
}

fn handle_menu_action(
    action: MenuAction,
    target: &tao::event_loop::EventLoopWindowTarget<UserEvent>,
    orb_ui: &OrbUiModel,
    web_panels: &mut Vec<WebPanel>,
    panel_proxy: &tao::event_loop::EventLoopProxy<UserEvent>,
) {
    match action {
        MenuAction::Settings => match open_settings_panel(target, orb_ui, panel_proxy) {
            Ok(panel) => web_panels.push(panel),
            Err(error) => log::error!("failed to open settings panel: {error}"),
        },
        MenuAction::Scheduler => match open_scheduler_panel(target, orb_ui, panel_proxy) {
            Ok(panel) => web_panels.push(panel),
            Err(error) => log::error!("failed to open scheduler panel: {error}"),
        },
        MenuAction::Skills => match open_skills_panel(target, orb_ui, panel_proxy) {
            Ok(panel) => web_panels.push(panel),
            Err(error) => log::error!("failed to open skills panel: {error}"),
        },
        MenuAction::SettingsLegacy | MenuAction::HideFae | MenuAction::Quit | MenuAction::Stop => {}
        other => {
            log::info!("stubbed Fae menu action: {other:?}");
        }
    }
}

/// The pill: Fae's whole conversation surface, a frosted window tucked beneath
/// the orb. Collapsed it shows one line — the current message, or the live
/// status (waking progress, Listening / Thinking… / Speaking) during a turn.
/// Click it to expand into a scrollable history + a composer; click-away, Esc,
/// or the chevron collapses it. Clickable and focusable (the composer needs
/// keyboard focus), unlike the old click-through status caption it replaced
/// (owner-approved UX, 2026-06-15).
struct PillPanel {
    window: Window,
    webview: WebView,
    /// Collapsed = one-line caption; expanded = scrollable history + composer.
    /// Drives the two window sizes and the JS `__faeExpand` toggle.
    expanded: bool,
    /// Last applied collapsed-caption height. Reset whenever an explicit
    /// collapse forces the window to its base size so the next content
    /// measurement cannot be discarded as a stale duplicate.
    last_collapsed_height: u32,
    /// Set to a `request_id` while the pill hosts a Swift `request_input` (UX
    /// W1): the composer is in prompted/masked mode. Cleared when the pill posts
    /// `input_response`/`input_cancel`. Focus-loss consults it so a click-away
    /// emits a cancel (freeing the Swift continuation) before collapsing.
    pending_input: Option<String>,
}

/// The pill's two window sizes, in **logical** points so the HTML/CSS (authored
/// in CSS px) lays out identically on 1x and retina displays — a `PhysicalSize`
/// here would halve the pill on a 2x screen and crush the composer layout.
const COLLAPSED_PILL: LogicalSize<u32> = LogicalSize::new(360, 52);
const EXPANDED_PILL: LogicalSize<u32> = LogicalSize::new(360, 440);

/// Orb long-press gesture state: hold ≥ [`LONG_PRESS_MS`] without moving past
/// [`PRESS_SLOP_PX`] → talk (release sends); move first → drag the orb.
#[derive(Clone, Copy, Debug, PartialEq)]
enum PressState {
    Idle,
    Pending {
        at: Instant,
        origin: PhysicalPosition<f64>,
    },
    Talking,
}

/// Hold duration before a stationary press becomes push-to-talk.
const LONG_PRESS_MS: u128 = 400;
/// Idle frame budget (~30 fps). The idle orb keeps a gentle breathing
/// animation rather than freezing on a still, but we cap the redraw rate with
/// `ControlFlow::WaitUntil` so the living-presence fog costs little battery
/// (`Poll` would render flat-out; `Wait` would freeze the orb dead).
const IDLE_FRAME_INTERVAL: Duration = Duration::from_millis(33);
/// Cursor travel that turns a pending press into a window drag.
const PRESS_SLOP_PX: f64 = 8.0;

fn build_webview_for_window<'a>(
    window: &'a Window,
    builder: WebViewBuilder<'a>,
) -> Result<WebView, Box<dyn Error>> {
    #[cfg(target_os = "linux")]
    {
        use tao::platform::unix::WindowExtUnix;
        use wry::WebViewBuilderExtUnix;

        let container = window
            .default_vbox()
            .ok_or_else(|| io::Error::other("tao GTK window missing default vbox"))?;
        Ok(builder.build_gtk(container)?)
    }

    #[cfg(not(target_os = "linux"))]
    {
        Ok(builder.build(window)?)
    }
}

fn open_pill_panel(
    target: &tao::event_loop::EventLoopWindowTarget<UserEvent>,
    panel_proxy: &tao::event_loop::EventLoopProxy<UserEvent>,
) -> Result<PillPanel, Box<dyn Error>> {
    // The pill is now the conversation surface: it must accept clicks and
    // keyboard focus (for the composer), so unlike the old caption window it is
    // neither click-through nor unfocused.
    //
    // Linux opaque frosted fallback: WebKitGTK cannot blur the desktop behind a
    // transparent webview (tauri#12800/#9220), so on Linux the pill renders as a
    // self-contained opaque frosted panel — solid window, solid webview
    // background, and the `.fae-opaque` HTML class baked onto <html> at build
    // time (first-paint-safe, no JS flash). macOS keeps the real frosted glass.
    let opaque = cfg!(target_os = "linux");
    let window = WindowBuilder::new()
        .with_title("Fae Conversation")
        .with_inner_size(COLLAPSED_PILL)
        .with_resizable(false)
        .with_decorations(false)
        .with_transparent(!opaque)
        .with_always_on_top(true)
        .build(target)?;
    let proxy = panel_proxy.clone();
    let (web_bg, html): ((u8, u8, u8, u8), String) = if opaque {
        (
            (22, 20, 28, 255),
            PILL_HTML.replace("<html class=\"\">", "<html class=\"fae-opaque\">"),
        )
    } else {
        ((0, 0, 0, 0), PILL_HTML.to_string())
    };
    let webview = build_webview_for_window(
        &window,
        WebViewBuilder::new()
            .with_transparent(!opaque)
            // Belt-and-braces: WKWebView paints a white canvas in light mode even
            // with a transparent body unless the background colour is cleared too.
            .with_background_color(web_bg)
            .with_html(html)
            .with_ipc_handler(move |request| {
                if let Err(error) = proxy.send_event(UserEvent::PanelAction(request.body().clone()))
                {
                    log::warn!("failed to forward pill IPC: {error}");
                }
            }),
    )?;
    Ok(PillPanel {
        window,
        webview,
        expanded: false,
        last_collapsed_height: COLLAPSED_PILL.height,
        pending_input: None,
    })
}

/// Toggle the pill between its collapsed caption and the expanded conversation
/// surface: resize the window, re-tuck it under the orb, drive the JS, and on
/// expand pull keyboard focus so the composer is ready to type.
fn set_pill_expanded(pill: &mut PillPanel, orb_window: &Window, expanded: bool) {
    pill.expanded = expanded;
    if !expanded {
        pill.last_collapsed_height = COLLAPSED_PILL.height;
    }
    pill.window.set_inner_size(if expanded {
        EXPANDED_PILL
    } else {
        COLLAPSED_PILL
    });
    position_pill(orb_window, pill);
    let script = if expanded {
        "window.__faeExpand(true);"
    } else {
        "window.__faeExpand(false);"
    };
    if let Err(error) = pill.webview.evaluate_script(script) {
        log::warn!("failed to toggle pill expansion: {error}");
    }
    if expanded {
        pill.window.set_focus();
    }
}

/// UX W1: put the pill into prompted-input mode for a Swift `request_input`.
/// Expand the window, then hand the request to the composer JS
/// (`__faeRequestInput`), which shows the prompt as the caption, masks the
/// field when `secure`, and posts `input_ack` so Swift commits to the pill path
/// (a 5s ack timeout falls back to the SwiftUI overlay). The composer answers
/// with `input_response`/`input_cancel`, both keyed by `request_id`.
fn pill_request_input(
    pill: &mut PillPanel,
    orb_window: &Window,
    request_id: String,
    prompt: &str,
    secure: bool,
    multiline: bool,
    placeholder: Option<&str>,
) {
    pill.expanded = true;
    pill.pending_input = Some(request_id.clone());
    pill.window.set_visible(true);
    pill.window.set_inner_size(EXPANDED_PILL);
    position_pill(orb_window, pill);
    let payload = serde_json::json!({
        "request_id": request_id,
        "prompt": prompt,
        "secure": secure,
        "multiline": multiline,
        "placeholder": placeholder.unwrap_or(""),
    });
    let script = format!("window.__faeRequestInput({payload});");
    if let Err(error) = pill.webview.evaluate_script(&script) {
        log::warn!("failed to drive pill request_input: {error}");
    }
    pill.window.set_focus();
}

/// Push the conversation history into the pill so it can show the latest line
/// when collapsed and the full scrollable log when expanded. Roles map to the
/// JS palette: `user`→"you" (heather), `fae`/`assistant`→"fae" (gold).
fn push_pill_messages(pill: &PillPanel, orb_ui: &OrbUiModel) {
    let mut payload = orb_ui
        .messages
        .iter()
        .map(|message| {
            let role = match message.role.to_lowercase().as_str() {
                "user" => "you".to_string(),
                "fae" | "assistant" => "fae".to_string(),
                _ => message.role.clone(),
            };
            serde_json::json!({ "role": role, "text": message.text })
        })
        .collect::<Vec<_>>();
    if orb_ui.has_distinct_streaming_text() {
        payload.push(serde_json::json!({
            "role": "fae",
            "text": orb_ui.streaming_text,
            "streaming": true,
        }));
    }
    let json = serde_json::to_string(&payload).unwrap_or_else(|_| "[]".to_string());
    if let Err(error) = pill
        .webview
        .evaluate_script(&format!("window.__faeSetMessages({json});"))
    {
        log::warn!("failed to push pill messages: {error}");
    }
    // Keep the pill speaker glyph in sync with the voice-mute state.
    if let Err(error) = pill.webview.evaluate_script(&format!(
        "window.__faeSetVoiceMute&&window.__faeSetVoiceMute({});",
        orb_ui.voice_muted
    )) {
        log::warn!("failed to push pill voice-mute state: {error}");
    }
}

const PILL_HTML: &str = r#"<!doctype html><html class=""><head><meta charset='utf-8'><style>
:root{color-scheme:dark;
 --bg:rgba(22,20,28,.78);--border:rgba(180,168,196,.22);
 --surface-frosted:rgba(26,24,32,.7);
 --text:rgba(255,255,255,.92);--muted:#9A90A8;--you:#B4A8C4;--fae:#D4A934;
 --serif:ui-serif,Georgia,'Times New Roman',serif;
 --sans:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif}
*{box-sizing:border-box}
html,body{margin:0;height:100%;background:transparent;overflow:hidden;
 font-family:var(--sans);color:var(--text)}
/* Linux opaque frosted fallback (class baked onto <html> on Linux only):
   WebKitGTK cannot blur the desktop, so paint a solid frosted panel instead. */
html.fae-opaque,html.fae-opaque body{background:#16141C}
html.fae-opaque #shell{background:#16141C;-webkit-backdrop-filter:none;
 backdrop-filter:none;box-shadow:none;border-color:rgba(180,168,196,.28)}
#shell{position:absolute;inset:8px;display:flex;flex-direction:column;
 background:var(--bg);border:1px solid var(--border);border-radius:9999px;
 box-shadow:0 10px 34px rgba(0,0,0,.42);
 -webkit-backdrop-filter:blur(22px) saturate(1.1);backdrop-filter:blur(22px) saturate(1.1);
 opacity:0;transform:translateY(2px);overflow:hidden;
 transition:opacity .22s cubic-bezier(0,0,.2,1),border-radius .26s cubic-bezier(.4,0,.2,1)}
#shell.show{opacity:1;transform:none}
#shell.expanded{border-radius:18px}
#line{display:flex;align-items:center;gap:9px;height:34px;min-height:34px;
 padding:0 15px;cursor:pointer;white-space:nowrap;overflow:hidden}
#shell.expanded #line{display:none}
#dot{width:7px;height:7px;border-radius:50%;flex:none;background:var(--muted);
 transition:background .2s,box-shadow .2s}
#dot.you{background:var(--you)}
#dot.fae{background:var(--fae);box-shadow:0 0 8px rgba(212,169,52,.5)}
#dot.live{animation:pulse 1.3s ease-in-out infinite}
#line.listen #dot{background:#8FB8A2;animation:pulse 1.2s ease-in-out infinite}
#txt{font:13px/1.3 var(--serif);overflow:hidden;text-overflow:ellipsis;flex:1 1 auto}
#line.muted #txt{color:var(--muted);font-family:var(--sans);font-size:12px}
@keyframes pulse{0%,100%{opacity:.45;transform:scale(.82)}50%{opacity:1;transform:scale(1.12)}}
#exp{display:none;flex-direction:column;flex:1 1 auto;min-height:0}
#shell.expanded #exp{display:flex}
#head{display:flex;align-items:center;justify-content:space-between;padding:11px 15px 7px;flex:none}
#head .l{font:11px var(--sans);letter-spacing:.08em;text-transform:uppercase;color:var(--muted)}
#cl{cursor:pointer;color:var(--muted);font-size:14px;line-height:1;padding:2px 6px;border-radius:6px}
#cl:hover{color:var(--text);background:rgba(255,255,255,.06)}
#log{flex:1 1 auto;min-height:0;overflow-y:auto;padding:4px 15px 8px;
 display:flex;flex-direction:column;gap:9px;scroll-behavior:smooth}
#log::-webkit-scrollbar{width:7px}
#log::-webkit-scrollbar-thumb{background:rgba(180,168,196,.22);border-radius:9999px}
.msg{display:flex;gap:9px;align-items:flex-start;animation:rise .2s ease-out}
.msg .d{width:6px;height:6px;border-radius:50%;margin-top:6px;flex:none;background:var(--muted)}
.msg.you .d{background:var(--you)}.msg.fae .d{background:var(--fae)}
.msg .b{font:13px/1.55 var(--serif);white-space:pre-wrap;word-break:break-word}
.msg.you .b{color:#CEC4DC}
@keyframes rise{from{opacity:0;transform:translateY(3px)}to{opacity:1;transform:none}}
#cmp{display:flex;flex-direction:column;gap:7px;padding:9px 11px 11px;flex:none;
 border-top:1px solid rgba(180,168,196,.14)}
#cmprow{display:flex;align-items:flex-end;gap:8px}
/* Long-paste chip: a frosted capsule summarising a pasted blob so the composer
 * isn't flooded (UX W1). Its full text still sends with the message. */
#chip{display:flex;align-items:center;gap:8px;align-self:flex-start;max-width:100%;
 background:var(--surface-frosted);border:1px solid var(--border);border-radius:9999px;
 padding:5px 6px 5px 12px}
#chip.hidden{display:none}
#chiptxt{font:12px var(--sans);color:var(--muted);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
#chipx{flex:none;width:18px;height:18px;border-radius:50%;border:none;cursor:pointer;padding:0;
 background:rgba(255,255,255,.08);color:var(--muted);font-size:13px;line-height:1;
 display:flex;align-items:center;justify-content:center}
#chipx:hover{color:var(--text);background:rgba(255,255,255,.14)}
#in{flex:1 1 auto;background:rgba(255,255,255,.04);border:1px solid var(--border);
 border-radius:16px;padding:7px 13px;color:var(--text);font:13px/1.4 var(--serif);outline:none;
 resize:none;min-height:34px;max-height:120px;overflow-y:auto}
#in::placeholder{color:var(--muted)}
#in:focus{border-color:rgba(212,169,52,.5)}
/* Secure request_input: mask characters (password style) without swapping the
 * element, and disable the paste-chip logic in JS. */
#in.secure{-webkit-text-security:disc;letter-spacing:.14em}
#snd{flex:none;width:30px;height:30px;border-radius:50%;border:none;cursor:pointer;
 background:var(--fae);color:#0F1013;font-size:15px;font-weight:600;
 display:flex;align-items:center;justify-content:center;opacity:.5;transition:opacity .15s}
#snd.ready{opacity:1}
/* Cancel (✕) affordance for request-input mode — a visible, always-clickable
 * escape hatch so an abandoned prompt can never trap the pointer. Hidden until
 * `#shell.req` (set by __faeRequestInput). */
#reqx{display:none;flex:none;width:30px;height:30px;border-radius:50%;
 border:1px solid var(--border);cursor:pointer;background:rgba(255,255,255,.06);
 color:var(--muted);font-size:17px;line-height:1;align-items:center;justify-content:center}
#reqx:hover{color:var(--text);background:rgba(255,255,255,.12)}
#shell.req #reqx{display:flex}
/* Masked-mode caption in fae-gold-text (DESIGN.md, 9.4:1 on dark). */
#hl.secure{color:#E6C05A}
/* Multi-line caption: the line fills the shell so a long reply SCROLLS inside
 * the pill (readable, not truncated) once it exceeds the grow-to-fit cap. */
#line.multi{height:auto;align-items:flex-start;padding:11px 16px;white-space:normal;
 flex:1 1 auto;min-height:0;overflow:hidden}
#line.multi #dot{margin-top:6px}
#line.multi #txt{white-space:pre-wrap;overflow-y:auto;overflow-x:hidden;text-overflow:clip;
 line-height:1.5;max-height:100%}
#line.multi #txt::-webkit-scrollbar{width:6px}
#line.multi #txt::-webkit-scrollbar-thumb{background:rgba(180,168,196,.22);border-radius:9999px}
#shell.multi{border-radius:20px}
/* Speaker glyph: the mute toggle at the end of the caption. Not emoji — an
 * inline SVG (DESIGN.md). Click posts a toggle_mute menu action to Swift.
 * Rendered as an always-visible frosted-glass button (soft fill + border) so
 * the owner can find and read it as a tappable control; gold (fae-gold) fill
 * + border when muted (DESIGN.md on-state accent). Visual prominence only —
 * the click action is unchanged. */
#vmute{flex:none;width:26px;height:26px;margin-left:6px;cursor:pointer;
 display:flex;align-items:center;justify-content:center;color:var(--text);
 background:rgba(255,255,255,.10);border:1px solid rgba(255,255,255,.18);border-radius:8px;
 transition:color .15s,background .15s,border-color .15s}
#vmute:hover{background:rgba(255,255,255,.16);border-color:rgba(255,255,255,.30)}
#vmute.muted{color:var(--fae);background:rgba(212,169,52,.15);border-color:rgba(212,169,52,.55)}
#vmute.muted:hover{background:rgba(212,169,52,.24)}
#vmute svg{width:17px;height:17px;display:block}
#line.multi #vmute{align-self:flex-start;margin-top:2px}
/* Info indicator: a second line under the caption — a green dot + summary,
 * shown only when the daemon has pushed `info.update` items. Click opens the
 * item's action (url/app/research page) via the orb-host router. */
#info{display:none;align-items:center;gap:8px;padding:0 15px 9px;cursor:pointer;
 white-space:nowrap;overflow:hidden}
#shell.has-info #info{display:flex}
#info .idot{width:7px;height:7px;border-radius:50%;flex:none;background:#5F7F6F;
 box-shadow:0 0 7px rgba(95,127,111,.55)}
#info .itxt{font:12px/1.3 var(--sans);color:#A9C2B6;overflow:hidden;text-overflow:ellipsis;flex:1 1 auto}
#info:hover .itxt{color:#C7D9CE}
</style></head><body>
<div id='shell'>
 <div id='line'><span id='dot'></span><span id='txt'></span><span id='vmute' title='Mute Fae'></span></div>
 <div id='info'><span class='idot'></span><span class='itxt'></span></div>
 <div id='exp'>
  <div id='head'><span class='l' id='hl'>Conversation</span><span id='cl'>⌄</span></div>
  <div id='log'></div>
  <div id='cmp'>
   <div id='chip' class='hidden'><span id='chiptxt'></span><button id='chipx' type='button'>×</button></div>
   <div id='cmprow'><button id='reqx' type='button' title='Cancel'>×</button><textarea id='in' rows='1' placeholder='Message Fae…' autocomplete='off'></textarea><button id='snd'>↑</button></div>
  </div>
 </div>
</div>
<script>(function(){
var shell=document.getElementById('shell'),line=document.getElementById('line'),
 dot=document.getElementById('dot'),txt=document.getElementById('txt'),log=document.getElementById('log'),
 input=document.getElementById('in'),snd=document.getElementById('snd'),cl=document.getElementById('cl'),
 exp=document.getElementById('exp'),cmp=document.getElementById('cmp'),hl=document.getElementById('hl'),
 chip=document.getElementById('chip'),chiptxt=document.getElementById('chiptxt'),chipx=document.getElementById('chipx'),
 reqx=document.getElementById('reqx'),vmute=document.getElementById('vmute');
var messages=[],status=null,infoItems=[],muted=false;
// UX W1 composer state: a Swift request_input in flight (request_id or null),
// whether the field is masked, and the full text of a long paste held as a chip.
var pendingInput=null,secureMode=false,pastedFull=null;
var post=function(o){if(window.ipc&&window.ipc.postMessage)window.ipc.postMessage(JSON.stringify(o));};
function rc(r){return r==='fae'?'fae':((r==='you'||r==='user')?'you':'');}
var captionFollowing=true,logFollowing=true;
var programmaticCaptionScroll=false,programmaticLogScroll=false;
function atBottom(el){return el.scrollHeight-el.scrollTop-el.clientHeight<=12;}
function beginScrollMutation(el,isCaption){
 var follow=isCaption?captionFollowing:logFollowing;
 if(isCaption)programmaticCaptionScroll=true;else programmaticLogScroll=true;
 return {follow:follow,top:el.scrollTop};}
function finishScrollMutation(el,s,isCaption){requestAnimationFrame(function(){
 el.scrollTop=s.follow?el.scrollHeight:s.top;
 requestAnimationFrame(function(){
  if(isCaption){programmaticCaptionScroll=false;captionFollowing=s.follow||atBottom(el);}
  else{programmaticLogScroll=false;logFollowing=s.follow||atBottom(el);}});});}
function scrollToBottom(el,isCaption){
 if(isCaption)programmaticCaptionScroll=true;else programmaticLogScroll=true;
 el.scrollTop=el.scrollHeight;requestAnimationFrame(function(){
  if(isCaption)programmaticCaptionScroll=false;else programmaticLogScroll=false;});}
txt.addEventListener('scroll',function(){
 if(!programmaticCaptionScroll)captionFollowing=atBottom(txt);});
log.addEventListener('scroll',function(){
 if(!programmaticLogScroll)logFollowing=atBottom(log);});
if(window.ResizeObserver){new ResizeObserver(function(){
 if(captionFollowing)scrollToBottom(txt,true);}).observe(txt);}
function setCaptionText(text){var s=beginScrollMutation(txt,true);
 txt.textContent=text;finishScrollMutation(txt,s,true);}
// Collapsed pill height: taller when the info indicator (second line) is shown
// so the green-dot line isn't clipped. Matches the Rust clamp (52..320).
function baseHeight(){return infoItems.length?78:52;}
function sizePill(isMsg){
 if(shell.classList.contains('expanded'))return;
 if(!isMsg){line.classList.remove('multi');shell.classList.remove('multi');
  post({type:'pill_resize',height:baseHeight()});return;}
 // Let the text wrap, then measure its FULL content height (scrollHeight — not
 // getBoundingClientRect, which is clipped by the window) and grow only
 // when it actually needs >1 line. Short lines stay a one-line pill; add the
 // info line height when the indicator is visible.
 line.classList.add('multi');shell.classList.add('multi');
 requestAnimationFrame(function(){
  var sh=txt.scrollHeight,multi=sh>26;
  line.classList.toggle('multi',multi);shell.classList.toggle('multi',multi);
  // Grow to fit, capped generously; beyond the cap the caption text scrolls.
  var h=multi?Math.min(320,Math.max(60,sh+30)):baseHeight();
  post({type:'pill_resize',height:h});
  if(captionFollowing)scrollToBottom(txt,true);});}
// Make a spoken reply readable: keep any real structure (newlines), else break
// a run-on paragraph into one line per sentence (caption style) so it doesn't
// read as a single dense block.
function formatBody(t){t=(t||'').trim();
 if(t.indexOf('\n')>=0)return t;
 return t.replace(/([.!?])\s+(?=[A-Z0-9"'(‘“])/g,'$1\n');}
function renderLine(){
 var m=messages[messages.length-1];
 if(status&&!(m&&m.streaming===true)){captionFollowing=true;line.className=(status.kind||'');dot.className=status.live?'live':'';
  setCaptionText(status.text);line.classList.toggle('muted',status.muted===true);sizePill(false);return;}
 if(m){line.className='';dot.className=rc(m.role);setCaptionText(formatBody(m.text));
  if(!shell.classList.contains('expanded'))sizePill(true);}
 else{captionFollowing=true;line.className='muted';dot.className='';setCaptionText('Hold right ⌥ to talk · click to see conversation');sizePill(false);}
}
function renderLog(){var s=beginScrollMutation(log,false);log.innerHTML='';messages.forEach(function(m){
 var e=document.createElement('div');e.className='msg '+rc(m.role);
 var d=document.createElement('span');d.className='d';
 var b=document.createElement('span');b.className='b';b.textContent=formatBody(m.text);
 e.appendChild(d);e.appendChild(b);log.appendChild(e);});finishScrollMutation(log,s,false);}
window.__faeSetMessages=function(a){messages=a||[];shell.classList.add('show');renderLine();
 if(shell.classList.contains('expanded'))renderLog();};
window.__faeSetStatus=function(kind,text,opts){opts=opts||{};
 status=kind?{kind:kind,text:text,live:opts.live===true,muted:opts.muted===true}:null;
 shell.classList.add('show');renderLine();};
// Speaker glyph (voice mute toggle). Inline SVG — never emoji (DESIGN.md).
var SPK_ON='<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M4 9v6h4l5 4V5L8 9H4z"/><path d="M16 9a4 4 0 0 1 0 6"/></svg>';
var SPK_OFF='<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M4 9v6h4l5 4V5L8 9H4z"/><path d="M16 9l5 6M21 9l-5 6"/></svg>';
function renderVMute(){vmute.innerHTML=muted?SPK_OFF:SPK_ON;
 vmute.classList.toggle('muted',muted);
 vmute.title=muted?'Fae muted — click to unmute':'Mute Fae';}
window.__faeSetVoiceMute=function(m){muted=(m===true);renderVMute();};
vmute.addEventListener('click',function(e){e.stopPropagation();
 post({type:'menu',action:'toggle_mute'});});
renderVMute();
// Auto-growing textarea: reset then grow to fit, capped (~6 rows) with internal
// scroll beyond. Send button lights when there's something to send.
function autoGrow(){input.style.height='auto';input.style.height=Math.min(input.scrollHeight,120)+'px';}
function updateReady(){snd.classList.toggle('ready',
 input.value.trim().length>0||pastedFull!==null||pendingInput!==null);}
function clearChip(){pastedFull=null;chip.classList.add('hidden');chiptxt.textContent='';}
function showChip(n){chiptxt.textContent='pasted · '+n+' chars';chip.classList.remove('hidden');}
// Leave request_input mode: restore the normal composer (called on collapse or
// when a new request arrives).
function exitRequestMode(){pendingInput=null;secureMode=false;
 shell.classList.remove('req');
 input.classList.remove('secure');hl.classList.remove('secure');hl.textContent='Conversation';
 input.placeholder='Message Fae…';clearChip();input.value='';autoGrow();updateReady();}
window.__faeExpand=function(on){if(on){shell.classList.add('expanded');renderLog();
 setTimeout(function(){input.focus();},30);}
 else{shell.classList.remove('expanded');if(pendingInput!==null)exitRequestMode();input.blur();renderLine();}};
// UX W1: enter prompted/masked input mode for a Swift request_input, then ack
// so Swift commits to the pill path (else it falls back to the overlay after 5s).
window.__faeRequestInput=function(o){o=o||{};
 pendingInput=(o.request_id!=null)?String(o.request_id):'';secureMode=o.secure===true;
 shell.classList.add('show','expanded','req');renderLog();clearChip();input.value='';
 hl.textContent=o.prompt||'';hl.classList.toggle('secure',secureMode);
 input.classList.toggle('secure',secureMode);
 input.placeholder=o.placeholder||(secureMode?'Type securely, then send':'Type your answer, then send');
 post({type:'input_ack',request_id:pendingInput});
 autoGrow();updateReady();setTimeout(function(){input.focus();},30);};
// Collapse intent: while a request is pending a collapse is a cancel (frees the
// Swift continuation); otherwise it's an ordinary pill collapse.
function requestCollapse(){
 if(pendingInput!==null)post({type:'input_cancel',request_id:pendingInput});
 else post({type:'pill_collapse'});}
line.addEventListener('click',function(){post({type:'pill_expand'});});
cl.addEventListener('click',function(e){e.stopPropagation();requestCollapse();});
// Click-to-collapse: while expanded, a click on the caption/body (anything
// OUTSIDE the composer) collapses — caret clicks inside the textarea and the
// send button are preserved.
exp.addEventListener('click',function(e){
 if(!shell.classList.contains('expanded'))return;
 if(cmp.contains(e.target))return;
 requestCollapse();});
input.addEventListener('input',function(){autoGrow();updateReady();});
// Long paste (>800 chars, non-secure) becomes a removable chip instead of
// flooding the composer; its full text still sends with the message.
input.addEventListener('paste',function(e){
 if(secureMode)return;
 var cd=e.clipboardData;if(!cd)return;
 var t=cd.getData('text');
 if(t&&t.length>800){e.preventDefault();pastedFull=t;showChip(t.length);updateReady();}});
chipx.addEventListener('click',function(e){e.stopPropagation();clearChip();updateReady();});
// Visible Cancel (✕) for request-input mode: always dismisses the prompt
// (posts input_cancel, frees the Swift continuation) and collapses the pill.
reqx.addEventListener('click',function(e){e.stopPropagation();requestCollapse();});
function submit(){
 if(pendingInput!==null){var v=input.value;
  post({type:'input_response',request_id:pendingInput,text:v});return;}
 var typed=input.value.trim();
 var full=pastedFull?(typed?typed+'\n\n'+pastedFull:pastedFull):typed;
 if(!full)return;
 post({type:'send_text',text:full});
 input.value='';clearChip();autoGrow();updateReady();}
snd.addEventListener('click',submit);
input.addEventListener('keydown',function(e){if(e.key==='Enter'&&!e.shiftKey){e.preventDefault();submit();}
 else if(e.key==='Escape'){e.preventDefault();requestCollapse();}});
function renderInfo(){
 var n=infoItems.length;
 shell.classList.toggle('has-info',n>0);
 if(!shell.classList.contains('expanded')){sizePill(false);}
 if(n===0)return;
 var box=document.getElementById('info');
 var t=box.querySelector('.itxt');
 t.textContent=(n===1)?(infoItems[0].title||'1 update'):(n+' updates');
}
window.__faeSetInfoItems=function(a){infoItems=Array.isArray(a)?a:[];renderInfo();};
document.getElementById('info').addEventListener('click',function(e){
 e.stopPropagation();var it=infoItems[0];if(!it)return;post({type:'info_action',id:it.id});});
renderLine();
})();</script></body></html>"#;

/// The live status line the pill should show during a turn, or None to clear it
/// (so the pill falls back to the latest conversation message). Returns
/// `(kind, text, opts)` where `opts` is a JS object literal forwarded verbatim
/// to `__faeSetStatus`. Owner decision: status takes priority over the latest
/// message while Fae is busy; when it clears, the message shows through.
fn pill_status(
    orb_ui: &OrbUiModel,
    thinking_secs: Option<u64>,
) -> Option<(&'static str, String, &'static str)> {
    match orb_ui.status_phase.as_str() {
        "starting" => {
            let pct = orb_ui
                .status_progress
                .map(|value| format!(" · {}%", (value * 100.0).round()))
                .unwrap_or_default();
            Some(("info", format!("{}{}", orb_ui.status_message, pct), "{}"))
        }
        "error" => Some(("alert", "Fae needs attention".to_string(), "{}")),
        "stopping" | "stopped" => None,
        _ => match orb_ui.ui_mode {
            FaeUiState::Listening => Some((
                "listen",
                "Listening — let go to send".to_string(),
                "{live:true}",
            )),
            FaeUiState::Thinking => {
                // Long turns (NaN retries) can run 30s+: a ticking counter
                // reads as progress where a static label reads as a hang.
                let text = match thinking_secs {
                    Some(secs) if secs >= 5 => format!("Thinking — {secs}s"),
                    _ => "Thinking…".to_string(),
                };
                Some(("info", text, "{live:true}"))
            }
            // Voice spine V4: during the reply, clear the status so the pill
            // shows the streaming response TEXT (the latest message) rather than
            // a static "Speaking" label — the orb's speaking glow already says
            // she's talking, and the owner wants to watch the words arrive.
            FaeUiState::Speaking => None,
            FaeUiState::Quiescent => {
                if !orb_ui.has_user_message() {
                    // The one teaching moment that matters: shown until the
                    // user's first turn of the session.
                    Some((
                        "hint",
                        "Hold right ⌥ to talk · click to see conversation".to_string(),
                        "{muted:true}",
                    ))
                } else {
                    // Idle with history: clear status so the pill shows the
                    // latest message.
                    None
                }
            }
        },
    }
}

fn refresh_pill(
    pill: &PillPanel,
    orb_ui: &OrbUiModel,
    thinking_secs: Option<u64>,
    last: &mut Option<(String, String)>,
) {
    let status = pill_status(orb_ui, thinking_secs);
    let keyed = match &status {
        Some((kind, text, _)) => ((*kind).to_string(), text.clone()),
        None => ("__clear__".to_string(), String::new()),
    };
    if last.as_ref() == Some(&keyed) {
        return;
    }
    *last = Some(keyed);
    let script = match status {
        Some((kind, text, opts)) => {
            let text_json = serde_json::to_string(&text).unwrap_or_else(|_| "\"\"".to_string());
            format!("window.__faeSetStatus('{kind}', {text_json}, {opts});")
        }
        None => "window.__faeSetStatus(null);".to_string(),
    };
    if let Err(error) = pill.webview.evaluate_script(&script) {
        log::warn!("failed to refresh pill status: {error}");
    }
}

/// Keep the pill tucked beneath the orb's glass, horizontally centred.
fn position_pill(orb_window: &Window, pill: &PillPanel) {
    let Ok(orb_position) = orb_window.outer_position() else {
        return;
    };
    let orb_size = orb_window.outer_size();
    let pill_size = pill.window.outer_size();
    let x = orb_position.x + (orb_size.width as i32 - pill_size.width as i32) / 2;
    let y = orb_position.y + (orb_size.height as f32 * 0.84) as i32;
    pill.window.set_outer_position(PhysicalPosition::new(x, y));
}

fn refresh_panel_kind(web_panels: &[WebPanel], kind: WebPanelKind, html: String) {
    let js_payload = match serde_json::to_string(&html) {
        Ok(payload) => payload,
        Err(error) => {
            log::warn!("failed to encode messages panel refresh payload: {error}");
            return;
        }
    };
    // Preserve the composer's draft text + focus, the help/controls collapse
    // state, and the thread scroll position across the rewrite — the panel
    // re-renders on every conversation update, mid-typing included.
    let script = format!(
        "(function() {{\
           const prior = document.getElementById('composer');\
           const draft = prior ? prior.value : '';\
           const hadFocus = prior && document.activeElement === prior;\
           const helpEl = document.getElementById('help');\
           const helpOpen = helpEl ? helpEl.open : null;\
           const ctrlEl = document.getElementById('controls');\
           const ctrlOpen = ctrlEl ? ctrlEl.open : null;\
           const thread = document.getElementById('thread');\
           const nearBottom = thread ? (thread.scrollHeight - thread.scrollTop - thread.clientHeight) < 90 : true;\
           document.open();document.write({js_payload});document.close();\
           const next = document.getElementById('composer');\
           if (next) {{ next.value = draft; if (hadFocus) next.focus(); }}\
           const help = document.getElementById('help');\
           if (help && helpOpen !== null) help.open = helpOpen;\
           const ctrl = document.getElementById('controls');\
           if (ctrl && ctrlOpen !== null) ctrl.open = ctrlOpen;\
           const t2 = document.getElementById('thread');\
           if (t2 && nearBottom) t2.scrollTop = t2.scrollHeight;\
         }})();"
    );
    for panel in web_panels.iter().filter(|panel| panel.kind == kind) {
        if let Err(error) = panel.webview.evaluate_script(&script) {
            log::warn!("failed to refresh panel: {error}");
        }
    }
}

fn refresh_scheduler_panels(web_panels: &[WebPanel], orb_ui: &OrbUiModel) {
    refresh_panel_kind(web_panels, WebPanelKind::Scheduler, scheduler_html(orb_ui));
}

fn refresh_skills_panels(web_panels: &[WebPanel], orb_ui: &OrbUiModel) {
    refresh_panel_kind(web_panels, WebPanelKind::Skills, skills_html(orb_ui));
}

fn refresh_settings_panels(web_panels: &[WebPanel], orb_ui: &OrbUiModel) {
    refresh_panel_kind(web_panels, WebPanelKind::Settings, settings_html(orb_ui));
}

fn html_escape(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#39;")
}

fn open_settings_panel(
    target: &tao::event_loop::EventLoopWindowTarget<UserEvent>,
    orb_ui: &OrbUiModel,
    panel_proxy: &tao::event_loop::EventLoopProxy<UserEvent>,
) -> Result<WebPanel, Box<dyn Error>> {
    let window = WindowBuilder::new()
        .with_title("Fae Settings")
        .with_inner_size(PhysicalSize::new(880, 680))
        .with_decorations(true)
        .with_always_on_top(true)
        .with_focused(true)
        .build(target)?;
    window.set_focus();
    let proxy = panel_proxy.clone();
    let webview = build_webview_for_window(
        &window,
        WebViewBuilder::new()
            .with_html(settings_html(orb_ui))
            .with_ipc_handler(move |request| {
                if let Err(error) = proxy.send_event(UserEvent::PanelAction(request.body().clone()))
                {
                    log::warn!("failed to forward settings panel IPC: {error}");
                }
            }),
    )?;
    window.set_focus();
    Ok(WebPanel {
        kind: WebPanelKind::Settings,
        window,
        webview,
    })
}

fn settings_html(orb_ui: &OrbUiModel) -> String {
    let sections = if orb_ui.settings_sections.is_empty() {
        "<section class='card'><h2>Waiting for settings</h2><p class='muted'>The Swift host has not sent a settings snapshot yet.</p></section>".to_string()
    } else {
        orb_ui
            .settings_sections
            .iter()
            .map(settings_section_html)
            .collect::<Vec<_>>()
            .join("\n")
    };

    let cards = if orb_ui.settings_cards.is_empty() {
        String::new()
    } else {
        orb_ui
            .settings_cards
            .iter()
            .map(settings_card_html)
            .collect::<Vec<_>>()
            .join("\n")
    };

    format!(
        r#"<!doctype html><html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'>
<style>
:root{{color-scheme:dark;--bg:#0F1013;--panel:#1A1820;--panel2:#221F28;--text:#CEC4DC;--soft:#9A90A8;--cream:#E8DED2;--gold:#D4A934;--gold-text:#E6C05A;--glen:#8FB8A2;--berry:#C4788A}}
*{{box-sizing:border-box}}
body{{margin:0;background:linear-gradient(135deg,#0F1013 0%,#18151D 52%,#221F28 100%);color:var(--text);font:14px -apple-system,BlinkMacSystemFont,Segoe UI,sans-serif}}
main{{min-height:100vh;padding:28px;display:grid;gap:18px}}
header{{border:1px solid rgba(180,168,196,.24);border-radius:22px;padding:24px;background:#1A1820;box-shadow:0 24px 80px rgba(0,0,0,.38)}}
h1{{margin:0 0 8px;font:42px 'Instrument Serif',Georgia,serif;color:var(--cream);letter-spacing:.01em}}
.lede{{margin:0;color:var(--soft);line-height:1.55;max-width:760px}}
.grid{{display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));gap:16px;align-items:start}}
.card{{border:1px solid rgba(180,168,196,.22);border-radius:18px;background:#1A1820;padding:18px;box-shadow:0 18px 48px rgba(0,0,0,.28)}}
h2{{margin:0 0 6px;font:27px 'Instrument Serif',Georgia,serif;color:var(--cream)}}
h3{{margin:0 0 5px;font-size:14px;color:var(--text)}}
p{{margin:0;line-height:1.5}}.muted{{color:var(--soft)}}
.setting{{display:grid;grid-template-columns:1fr minmax(120px,190px);gap:14px;align-items:center;padding:13px 0;border-top:1px solid rgba(255,255,255,.07)}}
.setting:first-of-type{{border-top:0}}
.desc{{font-size:12px;color:var(--soft)}}
input,select{{width:100%;border:1px solid rgba(180,168,196,.30);border-radius:10px;background:#0F1013;color:var(--text);padding:8px 10px;font:13px -apple-system,BlinkMacSystemFont,Segoe UI,sans-serif;outline:none}}
input:focus,select:focus{{border-color:rgba(212,169,52,.68);box-shadow:0 0 0 3px rgba(212,169,52,.10)}}
input[type='checkbox']{{width:22px;height:22px;justify-self:end;accent-color:var(--gold)}}
.number-control{{display:grid;grid-template-columns:34px 1fr 34px;gap:6px;align-items:center}}
.stepper{{border-radius:10px;padding:8px 0;line-height:1;color:var(--cream);background:rgba(212,169,52,.10)}}
.unit{{font-size:11px;color:var(--soft);margin-top:4px;text-align:right}}
.info-grid{{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:14px}}
.info{{border:1px solid rgba(143,184,162,.24);border-radius:16px;padding:15px;background:#17201D}}
.info h3{{color:#DDE8E1}}.info .detail{{margin-top:8px;font-size:12px;color:#A9BFB4}}
button{{border:1px solid rgba(212,169,52,.48);border-radius:999px;background:rgba(212,169,52,.14);color:var(--gold-text);padding:8px 13px;font:12px -apple-system,BlinkMacSystemFont,Segoe UI,sans-serif;cursor:pointer}}
.toolbar{{display:flex;gap:10px;align-items:center;justify-content:flex-end}}
@media(max-width:640px){{main{{padding:18px}}.setting{{grid-template-columns:1fr}}input[type='checkbox']{{justify-self:start}}}}
</style></head><body><main>
<header><h1>Fae Settings</h1><p class='lede'>Orb-owned settings for the adjustable runtime surface. Changes are sent to Swift through the bridge and persisted by FaeCore. Capability showcases below are informational cards, not authority toggles.</p></header>
<div class='toolbar'><button onclick='requestSnapshot()'>Refresh from Swift</button></div>
<div class='grid'>{sections}</div>
<section class='card'><h2>Always-on capabilities</h2><div class='info-grid'>{cards}</div></section>
<script>
function post(obj){{window.ipc.postMessage(JSON.stringify(obj));}}
function requestSnapshot(){{post({{type:'settings_request_snapshot'}});}}
function sendSetting(el){{
  const key = el.dataset.key;
  if (!key || el.disabled) return;
  const value = el.type === 'checkbox' ? String(el.checked) : String(el.value);
  post({{type:'settings_set', key, value}});
}}
function stepSetting(button){{
  const key = button.dataset.stepKey;
  const input = document.querySelector(`[data-key="${{key}}"]`);
  if (!input || input.disabled) return;
  const step = Number.parseFloat(button.dataset.step || input.step || '1');
  const direction = Number.parseFloat(button.dataset.direction || '0');
  const min = input.min === '' ? Number.NEGATIVE_INFINITY : Number.parseFloat(input.min);
  const max = input.max === '' ? Number.POSITIVE_INFINITY : Number.parseFloat(input.max);
  const current = Number.parseFloat(input.value || '0');
  const decimals = Math.max(0, ((input.step || '').split('.')[1] || '').length);
  const next = Math.min(max, Math.max(min, current + step * direction));
  input.value = next.toFixed(decimals);
  sendSetting(input);
}}
document.querySelectorAll('[data-key]').forEach((el)=>{{el.addEventListener('change',()=>sendSetting(el));}});
document.querySelectorAll('[data-step-key]').forEach((el)=>{{el.addEventListener('click',()=>stepSetting(el));}});
</script></main></body></html>"#,
        sections = sections,
        cards = cards
    )
}

fn settings_section_html(section: &SettingsSection) -> String {
    let description = section
        .description
        .as_deref()
        .map(|text| format!("<p class='muted'>{}</p>", html_escape(text)))
        .unwrap_or_default();
    let controls = section
        .settings
        .iter()
        .map(setting_item_html)
        .collect::<Vec<_>>()
        .join("\n");
    format!(
        "<section class='card' data-section='{id}'><h2>{title}</h2>{description}{controls}</section>",
        id = html_escape(&section.id),
        title = html_escape(&section.title),
        description = description,
        controls = controls
    )
}

fn setting_item_html(setting: &SettingItem) -> String {
    let control = setting_control_html(setting);
    format!(
        "<div class='setting'><div><h3>{title}</h3><p class='desc'>{description}</p></div><div>{control}{unit}</div></div>",
        title = html_escape(&setting.title),
        description = html_escape(&setting.description),
        control = control,
        unit = setting
            .unit
            .as_deref()
            .map(|unit| format!("<div class='unit'>{}</div>", html_escape(unit)))
            .unwrap_or_default()
    )
}

fn setting_control_html(setting: &SettingItem) -> String {
    let key = html_escape(&setting.key);
    let value = html_escape(&setting.value);
    let disabled = if setting.read_only.unwrap_or(false) {
        " disabled"
    } else {
        ""
    };
    match setting.kind.as_str() {
        "select" => {
            let options = setting
                .options
                .as_ref()
                .map(|items| {
                    items
                        .iter()
                        .map(|option| {
                            let selected = if option.value == setting.value {
                                " selected"
                            } else {
                                ""
                            };
                            format!(
                                "<option value='{value}'{selected}>{label}</option>",
                                value = html_escape(&option.value),
                                selected = selected,
                                label = html_escape(&option.label)
                            )
                        })
                        .collect::<Vec<_>>()
                        .join("")
                })
                .unwrap_or_default();
            format!("<select data-key='{key}'{disabled}>{options}</select>")
        }
        "bool" => {
            let checked = if setting.value == "true" { " checked" } else { "" };
            format!("<input data-key='{key}' type='checkbox'{checked}{disabled}>")
        }
        "number" | "int" => format!(
            "<div class='number-control'><button class='stepper' type='button' data-step-key='{key}' data-step='{step}' data-direction='-1'{disabled}>−</button><input data-key='{key}' type='number' value='{value}' min='{min}' max='{max}' step='{step}'{disabled}><button class='stepper' type='button' data-step-key='{key}' data-step='{step}' data-direction='1'{disabled}>+</button></div>",
            min = html_escape(setting.min.as_deref().unwrap_or("")),
            max = html_escape(setting.max.as_deref().unwrap_or("")),
            step = html_escape(setting.step.as_deref().unwrap_or("1"))
        ),
        "readonly" => format!("<input value='{value}' disabled>"),
        _ => format!("<input data-key='{key}' value='{value}'{disabled}>"),
    }
}

fn settings_card_html(card: &SettingsCard) -> String {
    let detail = card
        .detail
        .as_deref()
        .map(|text| format!("<p class='detail'>{}</p>", html_escape(text)))
        .unwrap_or_default();
    format!(
        "<article class='info'><h3>{title}</h3><p>{body}</p>{detail}</article>",
        title = html_escape(&card.title),
        body = html_escape(&card.body),
        detail = detail
    )
}

fn open_scheduler_panel(
    target: &tao::event_loop::EventLoopWindowTarget<UserEvent>,
    orb_ui: &OrbUiModel,
    panel_proxy: &tao::event_loop::EventLoopProxy<UserEvent>,
) -> Result<WebPanel, Box<dyn Error>> {
    let window = WindowBuilder::new()
        .with_title("Fae Scheduler")
        .with_inner_size(PhysicalSize::new(700, 560))
        .with_decorations(true)
        .with_always_on_top(true)
        .build(target)?;
    let proxy = panel_proxy.clone();
    let webview = build_webview_for_window(
        &window,
        WebViewBuilder::new()
            .with_html(scheduler_html(orb_ui))
            .with_ipc_handler(move |request| {
                if let Err(error) = proxy.send_event(UserEvent::PanelAction(request.body().clone()))
                {
                    log::warn!("failed to forward scheduler panel IPC: {error}");
                }
            }),
    )?;
    Ok(WebPanel {
        kind: WebPanelKind::Scheduler,
        window,
        webview,
    })
}

fn open_skills_panel(
    target: &tao::event_loop::EventLoopWindowTarget<UserEvent>,
    orb_ui: &OrbUiModel,
    panel_proxy: &tao::event_loop::EventLoopProxy<UserEvent>,
) -> Result<WebPanel, Box<dyn Error>> {
    let window = WindowBuilder::new()
        .with_title("Fae Skills")
        .with_inner_size(PhysicalSize::new(700, 560))
        .with_decorations(true)
        .with_always_on_top(true)
        .build(target)?;
    let proxy = panel_proxy.clone();
    let webview = build_webview_for_window(
        &window,
        WebViewBuilder::new()
            .with_html(skills_html(orb_ui))
            .with_ipc_handler(move |request| {
                if let Err(error) = proxy.send_event(UserEvent::PanelAction(request.body().clone()))
                {
                    log::warn!("failed to forward skills panel IPC: {error}");
                }
            }),
    )?;
    Ok(WebPanel {
        kind: WebPanelKind::Skills,
        window,
        webview,
    })
}

fn scheduler_html(orb_ui: &OrbUiModel) -> String {
    let tasks = if orb_ui.scheduler_tasks.is_empty() {
        "<p class='empty'>No scheduler items yet.</p>".to_string()
    } else {
        orb_ui
            .scheduler_tasks
            .iter()
            .map(|task| {
                format!(
                    "<article class='item'><div><h2>{name}</h2><p>{schedule}</p><p class='muted'>{id} · last: {last_run} · next: {next_run}</p></div><div class='actions'><span class='pill {enabled_class}'>{status}</span><button data-action='scheduler_toggle' data-id='{id}' data-enabled='{next_enabled}' onclick='postAction(this)'>{button}</button></div></article>",
                    name = html_escape(&task.name),
                    schedule = html_escape(&task.schedule),
                    id = html_escape(&task.id),
                    last_run = html_escape(task.last_run.as_deref().unwrap_or("never")),
                    next_run = html_escape(task.next_run.as_deref().unwrap_or("not scheduled")),
                    enabled_class = if task.enabled { "enabled" } else { "disabled" },
                    status = html_escape(&task.status),
                    next_enabled = if task.enabled { "false" } else { "true" },
                    button = if task.enabled { "Disable" } else { "Enable" }
                )
            })
            .collect::<Vec<_>>()
            .join("\n")
    };
    panel_list_html("Scheduler", "Orb-owned automation status", &tasks)
}

fn skills_html(orb_ui: &OrbUiModel) -> String {
    let skills = if orb_ui.skills.is_empty() {
        "<p class='empty'>No skills installed yet.</p>".to_string()
    } else {
        orb_ui
            .skills
            .iter()
            .map(|skill| {
                let state = if skill.active {
                    "active"
                } else if skill.enabled {
                    "enabled"
                } else {
                    "disabled"
                };
                format!(
                    "<article class='item'><div><h2>{name}</h2><p>{description}</p><p class='muted'>{skill_type} · {tier}</p></div><div class='actions'><span class='pill {state}'>{state}</span><button data-action='skill_toggle' data-id='{name}' data-active='{next_active}' onclick='postAction(this)'>{button}</button></div></article>",
                    name = html_escape(&skill.id),
                    description = html_escape(&skill.description),
                    skill_type = html_escape(&skill.skill_type),
                    tier = html_escape(&skill.tier),
                    state = state,
                    next_active = if skill.active { "false" } else { "true" },
                    button = if skill.active { "Deactivate" } else { "Activate" }
                )
            })
            .collect::<Vec<_>>()
            .join("\n")
    };
    panel_list_html("Skills", "Orb-owned skill inventory", &skills)
}

fn panel_list_html(title: &str, subtitle: &str, body: &str) -> String {
    format!(
        r#"<!doctype html><html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'><style>body{{margin:0;background:radial-gradient(circle at 50% 0,#221F28,#0F1013 64%);color:#CEC4DC;font:15px -apple-system,BlinkMacSystemFont,Segoe UI,sans-serif}}main{{padding:26px;display:grid;gap:14px}}header{{border:1px solid rgba(180,168,196,.25);border-radius:16px;padding:22px;background:#1A1820;box-shadow:0 24px 80px rgba(0,0,0,.34)}}h1{{margin:0 0 8px;font-size:28px;font-family:'Instrument Serif',Georgia,serif;color:#E8DED2}}h2{{margin:0 0 6px;font-size:17px;color:#CEC4DC}}.muted,.empty{{color:#9A90A8}}.item{{display:flex;justify-content:space-between;gap:16px;border:1px solid rgba(255,255,255,.08);border-radius:16px;padding:16px;background:#1A1820}}.actions{{display:flex;flex-direction:column;gap:8px;align-items:flex-end}}button{{border:1px solid rgba(212,169,52,.45);border-radius:6px;background:rgba(212,169,52,.16);color:#E6C05A;padding:7px 11px;font:12px -apple-system,BlinkMacSystemFont,Segoe UI,sans-serif;cursor:pointer}}p{{line-height:1.45;margin:0}}.pill{{align-self:start;border-radius:999px;padding:6px 10px;background:rgba(255,255,255,.10);font-size:12px;text-transform:uppercase;letter-spacing:.08em;color:#9A90A8}}.pill.enabled,.pill.active{{background:rgba(212,169,52,.22);color:#E6C05A}}.pill.disabled{{opacity:.58}}</style></head><body><main><header><h1>{title}</h1><p class='muted'>{subtitle}</p></header>{body}</main><script>function postAction(el){{const payload={{type:el.dataset.action,id:el.dataset.id}};if(el.dataset.enabled!==undefined)payload.enabled=el.dataset.enabled==='true';if(el.dataset.active!==undefined)payload.active=el.dataset.active==='true';window.ipc.postMessage(JSON.stringify(payload));}}</script></body></html>"#,
        title = html_escape(title),
        subtitle = html_escape(subtitle),
        body = body
    )
}

fn show_context_menu(menu: &OrbMenu, window: &Window, position: PhysicalPosition<f64>) {
    #[cfg(target_os = "macos")]
    unsafe {
        use muda::ContextMenu;
        menu.menu
            .show_context_menu_for_nsview(window.ns_view(), Some(position.into()));
    }

    #[cfg(not(target_os = "macos"))]
    {
        let _ = (&menu.menu, window, position);
        log::warn!("context menu popup is not wired for this platform yet");
    }
}

/// Install a minimal macOS application menu carrying only the standard Edit
/// commands (Undo/Redo · Cut/Copy/Paste/Select All).
///
/// The orb host runs as an `Accessory` app, so this menu is never drawn in the
/// system menubar and adds no Dock icon — AppKit accessory apps do not own the
/// menubar. Its sole purpose is to register the ⌘Z/⌘X/⌘C/⌘V/⌘A key equivalents
/// on `NSApp.mainMenu` so that `-[NSApplication sendEvent:]` routes them through
/// `performKeyEquivalent:` into the focused first responder — the pill's
/// WKWebView. Without a main-menu Edit item, ⌘V is delivered as a bare keyDown
/// that the WebView does not act on, so paste into the composer is dead.
///
/// Quit is intentionally omitted: ⌘Q stays owned by the Swift host
/// (`WindowEvent::CloseRequested` → `MenuAction::Quit`, which tells Swift to
/// terminate the whole app). A `terminate:` item here would kill only the orb
/// host process and trigger its auto-respawn, splitting the quit path.
///
/// The menu is leaked so the `NSMenu` outlives this call; `NSApplication`
/// retains it as its main menu for the process lifetime (mirrors the leaked orb
/// window). Must be called on the main thread after the event loop is built
/// (so `NSApplication` exists). Predefined items act via native selectors and
/// emit no `muda::MenuEvent`, so this never interferes with the OrbMenu context
/// menu or the stdout menu-event path.
#[cfg(target_os = "macos")]
fn install_edit_menubar() -> Result<(), muda::Error> {
    use muda::{Menu, PredefinedMenuItem, Submenu};

    let menubar = Menu::new();
    // A leading (empty) app submenu keeps the conventional structure so AppKit
    // treats the second submenu as Edit rather than the app menu.
    let app_menu = Submenu::new("Fae", true);
    let edit_menu = Submenu::new("Edit", true);
    edit_menu.append(&PredefinedMenuItem::undo(None))?;
    edit_menu.append(&PredefinedMenuItem::redo(None))?;
    edit_menu.append(&PredefinedMenuItem::separator())?;
    edit_menu.append(&PredefinedMenuItem::cut(None))?;
    edit_menu.append(&PredefinedMenuItem::copy(None))?;
    edit_menu.append(&PredefinedMenuItem::paste(None))?;
    edit_menu.append(&PredefinedMenuItem::select_all(None))?;
    menubar.append(&app_menu)?;
    menubar.append(&edit_menu)?;
    menubar.init_for_nsapp();
    Box::leak(Box::new(menubar));
    Ok(())
}

#[cfg(test)]
mod v4_tests {
    use super::{apply_audio_patch, rms_to_level, OrbUiModel};
    use crate::protocol::AudioPatch;

    fn approx(level: Option<f32>, expected: f32) -> bool {
        level.map(|v| (v - expected).abs() < 1e-5).unwrap_or(false)
    }

    #[test]
    fn set_maps_raw_rms_into_the_expressive_band() {
        // Raw TTS RMS is quiet; Set lifts it so a pause sits near the rest
        // breath and speech peaks swell well above it (the live bug: raw RMS
        // ~0.03 rode the orb BELOW its ~0.12 breath baseline).
        let mut level = None;
        apply_audio_patch(AudioPatch::Set(0.0), &mut level);
        assert!(approx(level, 0.18), "silence → rest level, got {level:?}");
        apply_audio_patch(AudioPatch::Set(0.06), &mut level);
        assert!(approx(level, 0.39), "mid speech → mid swell, got {level:?}");
        apply_audio_patch(AudioPatch::Set(0.12), &mut level);
        assert!(
            approx(level, 0.60),
            "strong speech → full swell, got {level:?}"
        );
        // Monotonic + always above the rest breath while speaking.
        assert!(rms_to_level(0.02) > rms_to_level(0.0));
    }

    #[test]
    fn set_clamps_oversized_and_negative_into_the_band() {
        // RMS can briefly exceed the band or glitch negative — clamp into 0.18…0.60.
        let mut level = None;
        apply_audio_patch(AudioPatch::Set(1.7), &mut level);
        assert!(
            approx(level, 0.60),
            "oversize clamps to full, got {level:?}"
        );
        apply_audio_patch(AudioPatch::Set(-0.4), &mut level);
        assert!(
            approx(level, 0.18),
            "negative clamps to rest, got {level:?}"
        );
    }

    #[test]
    fn clear_resets_the_ride() {
        // Explicit `null` → Clear → orb returns to synthetic breath.
        let mut level = Some(0.8);
        apply_audio_patch(AudioPatch::Clear, &mut level);
        assert_eq!(level, None);
    }

    #[test]
    fn unchanged_does_not_clobber_an_in_progress_ride() {
        // The crucial V4 invariant: a mode/status command that OMITS `audio`
        // (→ Unchanged) must NOT clear an in-progress ride. Without this, every
        // plain `sendState` would reset the orb to the synthetic breath.
        let mut level = Some(0.6);
        apply_audio_patch(AudioPatch::Unchanged, &mut level);
        assert_eq!(level, Some(0.6));
    }

    #[test]
    fn distinct_nonempty_streaming_text_is_active() {
        let mut model = OrbUiModel::new();
        model.set_streaming_text("A response in progress".to_string());

        assert!(model.has_distinct_streaming_text());
    }

    #[test]
    fn finalized_fae_or_assistant_message_suppresses_identical_streaming_text() {
        for role in ["fae", "assistant"] {
            let mut model = OrbUiModel::new();
            model.set_streaming_text("The completed response".to_string());
            model.push_message(role.to_string(), "The completed response".to_string());

            assert!(
                !model.has_distinct_streaming_text(),
                "finalized {role} message should suppress the identical transient"
            );
        }
    }

    #[test]
    fn user_or_different_trailing_message_does_not_suppress_streaming_text() {
        let mut user_trailing = OrbUiModel::new();
        user_trailing.set_streaming_text("Shared text".to_string());
        user_trailing.push_message("user".to_string(), "Shared text".to_string());
        assert!(user_trailing.has_distinct_streaming_text());

        let mut different_assistant = OrbUiModel::new();
        different_assistant.set_streaming_text("Current response".to_string());
        different_assistant.push_message("assistant".to_string(), "Earlier response".to_string());
        assert!(different_assistant.has_distinct_streaming_text());
    }

    #[test]
    fn clearing_streaming_text_removes_transient() {
        let mut model = OrbUiModel::new();
        model.set_streaming_text("A response in progress".to_string());
        assert!(model.has_distinct_streaming_text());

        model.set_streaming_text(String::new());

        assert!(!model.has_distinct_streaming_text());
    }
}
