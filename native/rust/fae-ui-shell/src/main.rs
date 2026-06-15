mod menu;
mod protocol;

use std::{
    error::Error,
    io::{self, BufRead, Write},
    thread,
    time::{Duration, Instant},
};

use menu::{MenuAction, OrbMenu};
use protocol::{
    FaeUiState, SchedulerTask, SettingItem, SettingOption, SettingsCard, SettingsSection,
    ShellCommand, SkillSummary,
};
use tao::{
    dpi::{PhysicalPosition, PhysicalSize},
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
    BrowserData,
    Messages,
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
    /// Latest pipeline mode from the State command — drives the whisper pill
    /// and the Messages-panel mic affordance.
    ui_mode: FaeUiState,
    /// Tool-access mode + thinking level for the panel's Controls strip.
    access: String,
    thinking: String,
    messages: Vec<TranscriptMessage>,
    scheduler_tasks: Vec<SchedulerTask>,
    skills: Vec<SkillSummary>,
    settings_sections: Vec<SettingsSection>,
    settings_cards: Vec<SettingsCard>,
}

impl OrbUiModel {
    fn new() -> Self {
        Self {
            status_phase: "starting".to_string(),
            status_message: "Starting Fae".to_string(),
            status_progress: None,
            ui_mode: FaeUiState::Quiescent,
            access: "full".to_string(),
            thinking: "fast".to_string(),
            messages: Vec::new(),
            scheduler_tasks: Vec::new(),
            skills: Vec::new(),
            settings_sections: Vec::new(),
            settings_cards: Vec::new(),
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
}

impl State {
    async fn new(window: &'static Window) -> Result<Self, Box<dyn Error>> {
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
        let alpha_mode = surface_caps
            .alpha_modes
            .iter()
            .copied()
            .find(|mode| *mode == wgpu::CompositeAlphaMode::PreMultiplied)
            .or_else(|| {
                surface_caps
                    .alpha_modes
                    .iter()
                    .copied()
                    .find(|mode| *mode == wgpu::CompositeAlphaMode::PostMultiplied)
            })
            .or_else(|| surface_caps.alpha_modes.first().copied())
            .ok_or("surface has no supported alpha modes")?;
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

    fn set_audio(&mut self, audio: Option<f32>) {
        if let Some(audio) = audio {
            self.bridge_audio = Some(audio.clamp(0.0, 1.0));
        }
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
            // Calm idle breath: lower baseline, gentler swing, slower period.
            0.05 + 0.04 * (0.5 + 0.5 * (time * 0.45).sin())
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
                        load: wgpu::LoadOp::Clear(wgpu::Color {
                            r: 0.0,
                            g: 0.0,
                            b: 0.0,
                            a: 0.0,
                        }),
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

    let mut event_loop_builder = EventLoopBuilder::<UserEvent>::with_user_event();
    #[allow(unused_mut)]
    let mut event_loop = event_loop_builder.build();
    // The orb host is part of Fae, not a second app: no Dock icon, no app
    // menu, no Cmd+Q identity of its own. Quit flows through the Swift host.
    #[cfg(target_os = "macos")]
    {
        use tao::platform::macos::{ActivationPolicy, EventLoopExtMacOS};
        event_loop.set_activation_policy(ActivationPolicy::Accessory);
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
    let orb_menu = OrbMenu::new()?;
    let mut state = pollster::block_on(State::new(window))?;
    let mut orb_ui = OrbUiModel::new();
    let mut cursor_position = PhysicalPosition::new(210.0, 210.0);
    let mut web_panels: Vec<WebPanel> = Vec::new();
    let pill = open_pill_panel(&event_loop)?;
    position_pill(window, &pill);
    let mut hovering = false;
    let mut last_pill: Option<(String, String)> = None;
    // When Fae entered thinking mode — drives the pill's elapsed counter so
    // long turns (NaN retries can take 30s+) read as progress, not a hang.
    let mut thinking_since: Option<Instant> = None;
    // Orb long-press gesture (owner design, touch-friendly): press-and-HOLD
    // starts capture (release sends); moving past the slop before the hold
    // fires means the user is dragging the orb, not talking.
    let mut press = PressState::Idle;
    refresh_pill(&pill, &orb_ui, hovering, None, &mut last_pill);

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
                }
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
                refresh_pill(
                    &pill,
                    &orb_ui,
                    hovering,
                    thinking_since.map(|since| since.elapsed().as_secs()),
                    &mut last_pill,
                );
                window.request_redraw();
            }
            Event::UserEvent(UserEvent::PanelAction(action_json)) => {
                emit_panel_action(&action_json);
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
                WindowEvent::CursorEntered { .. } => {
                    hovering = true;
                    refresh_pill(
                        &pill,
                        &orb_ui,
                        hovering,
                        thinking_since.map(|since| since.elapsed().as_secs()),
                        &mut last_pill,
                    );
                }
                WindowEvent::CursorLeft { .. } => {
                    hovering = false;
                    refresh_pill(
                        &pill,
                        &orb_ui,
                        hovering,
                        thinking_since.map(|since| since.elapsed().as_secs()),
                        &mut last_pill,
                    );
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
                    if is_messages_button_hit(cursor_position, state.size) {
                        match open_messages_panel(target, &orb_ui, &panel_proxy) {
                            Ok(panel) => web_panels.push(panel),
                            Err(error) => log::error!("failed to open messages panel: {error}"),
                        }
                    } else {
                        // Press intent is decided by what happens next: hold
                        // still ≥ LONG_PRESS_MS → talk; move first → drag.
                        press = PressState::Pending {
                            at: Instant::now(),
                            origin: cursor_position,
                        };
                    }
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
                        // A short stationary click: not a gesture — pulse the
                        // pill so the hold/drag affordances get taught.
                        press = PressState::Idle;
                        if let Err(error) = pill.webview.evaluate_script("window.__pillPulse();") {
                            log::warn!("failed to pulse whisper pill: {error}");
                        }
                        refresh_pill(
                            &pill,
                            &orb_ui,
                            true,
                            thinking_since.map(|since| since.elapsed().as_secs()),
                            &mut last_pill,
                        );
                    }
                    PressState::Idle => {}
                },
                _ => {}
            },
            Event::WindowEvent {
                event, window_id, ..
            } => {
                if matches!(event, WindowEvent::CloseRequested) {
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
                // Tick the thinking counter once a second (refresh_pill dedupes
                // by content, so per-frame calls only repaint on text change).
                if thinking_since.is_some() {
                    refresh_pill(
                        &pill,
                        &orb_ui,
                        hovering,
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

fn emit_panel_action(action_json: &str) {
    let mut stdout = io::stdout().lock();
    if let Err(error) = writeln!(stdout, "{action_json}") {
        log::warn!("failed to write panel action to stdout: {error}");
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
            let active = matches!(
                ui_state,
                FaeUiState::Thinking | FaeUiState::Speaking | FaeUiState::Listening
            );
            orb_ui.ui_mode = ui_state;
            state.set_active(active);
            state.set_audio(audio);
            state.set_emotion(ui_state, feeling.as_deref());
            state.set_status_progress(None, false);
            refresh_messages_panels(web_panels, orb_ui);
            window.set_visible(true);
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
                state.set_audio(Some(progress));
            }
            refresh_messages_panels(web_panels, orb_ui);
            // Status changes animate the orb but never hide it (S18: the orb
            // is the talk button and must stay clickable while idle).
            window.set_visible(true);
        }
        ShellCommand::Conversation { role, text } => {
            orb_ui.push_message(role, text);
            refresh_messages_panels(web_panels, orb_ui);
        }
        ShellCommand::ClearConversation => {
            orb_ui.clear_messages();
            refresh_messages_panels(web_panels, orb_ui);
        }
        ShellCommand::SchedulerSnapshot { tasks } => {
            orb_ui.set_scheduler_tasks(tasks);
            refresh_scheduler_panels(web_panels, orb_ui);
        }
        ShellCommand::SkillsSnapshot { skills } => {
            orb_ui.set_skills(skills);
            refresh_skills_panels(web_panels, orb_ui);
        }
        ShellCommand::ControlsSnapshot { access, thinking } => {
            orb_ui.access = access;
            orb_ui.thinking = thinking;
            refresh_messages_panels(web_panels, orb_ui);
        }
        ShellCommand::SettingsSnapshot { sections, cards } => {
            orb_ui.set_settings(sections, cards);
            refresh_settings_panels(web_panels, orb_ui);
        }
        ShellCommand::ShowMessages => {
            log::info!(
                "show_messages bridge command ignored; Messages opens from orb-owned menu/button"
            )
        }
        ShellCommand::Show => {
            state.set_active(true);
            window.set_visible(true);
        }
        ShellCommand::Hide => {
            state.set_active(false);
            window.set_visible(false);
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
        MenuAction::ShowMessages => match open_messages_panel(target, orb_ui, panel_proxy) {
            Ok(panel) => web_panels.push(panel),
            Err(error) => log::error!("failed to open messages panel: {error}"),
        },
        MenuAction::OpenBrowserDataPanel => match open_browser_data_panel(target, orb_ui) {
            Ok(panel) => web_panels.push(panel),
            Err(error) => log::error!("failed to open browser/data panel: {error}"),
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

/// The whisper pill: a small frosted, click-through caption window that sits
/// beneath the orb and says what Fae is doing — waking progress, the first-run
/// "Click me and speak" hint, listening/thinking/speaking, and gesture help on
/// hover. It exists because the orb alone cannot teach a new user the
/// click-to-talk gesture or show load progress legibly (owner-approved UX,
/// 2026-06-12). Click-through so it never steals the orb's clicks.
struct PillPanel {
    window: Window,
    webview: WebView,
}

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
    target: &tao::event_loop::EventLoop<UserEvent>,
) -> Result<PillPanel, Box<dyn Error>> {
    let window = WindowBuilder::new()
        .with_title("Fae Status")
        .with_inner_size(PhysicalSize::new(380, 48))
        .with_resizable(false)
        .with_decorations(false)
        .with_transparent(true)
        .with_always_on_top(true)
        .with_focused(false)
        .build(target)?;
    if let Err(error) = window.set_ignore_cursor_events(true) {
        log::warn!("pill window could not be made click-through: {error}");
    }
    let webview = build_webview_for_window(
        &window,
        WebViewBuilder::new()
            .with_transparent(true)
            // Belt-and-braces: WKWebView paints a white canvas in light mode even
            // with a transparent body unless the background colour is cleared too.
            .with_background_color((0, 0, 0, 0))
            .with_html(PILL_HTML),
    )?;
    Ok(PillPanel { window, webview })
}

const PILL_HTML: &str = r#"<!doctype html><html><head><meta charset='utf-8'><style>
:root{color-scheme:dark}
html,body{margin:0;background:transparent;overflow:hidden;height:100%}
#pill{position:absolute;left:50%;top:50%;transform:translate(-50%,-50%);max-width:94%;
 display:flex;align-items:center;gap:7px;padding:7px 14px;border-radius:9999px;
 background:rgba(26,24,32,.84);border:1px solid rgba(180,168,196,.25);
 color:#CEC4DC;font:12px -apple-system,BlinkMacSystemFont,sans-serif;white-space:nowrap;
 overflow:hidden;text-overflow:ellipsis;opacity:0;
 transition:opacity .2s cubic-bezier(0,0,.2,1);box-shadow:0 8px 30px rgba(0,0,0,.35)}
#pill.show{opacity:1}
#pill.hint{border-color:rgba(212,169,52,.5);color:#E6C05A}
#pill.listen{border-color:rgba(122,155,142,.7)}
#pill.alert{border-color:rgba(196,120,138,.6);color:#C4788A}
#dot{width:7px;height:7px;border-radius:50%;background:#7A9B8E;display:none;flex:none}
#pill.listen #dot{display:block;animation:pulse 1.2s ease-in-out infinite}
@keyframes pulse{0%,100%{opacity:.4;transform:scale(.85)}50%{opacity:1;transform:scale(1.15)}}
@keyframes nudge{0%,100%{transform:translate(-50%,-50%) scale(1)}40%{transform:translate(-50%,-50%) scale(1.07)}}
</style></head><body>
<div id='pill'><span id='dot'></span><span id='txt'></span></div>
<script>
window.__setPill=function(text,kind){var p=document.getElementById('pill');
 if(!text){p.className='';return;}
 document.getElementById('txt').textContent=text;p.className='show '+(kind||'info');};
window.__pillPulse=function(){var p=document.getElementById('pill');
 p.style.animation='none';void p.offsetWidth;p.style.animation='nudge .3s ease-out';};
</script></body></html>"#;

/// What the pill should say right now, or None to fade it out.
/// Owner decision (2026-06-12): Right ⌥ hold-to-talk is THE capture gesture
/// — the mouse only moves the orb — so every line teaches the key, not clicks.
fn pill_content(
    orb_ui: &OrbUiModel,
    hovering: bool,
    thinking_secs: Option<u64>,
) -> Option<(String, &'static str)> {
    match orb_ui.status_phase.as_str() {
        "starting" => {
            let pct = orb_ui
                .status_progress
                .map(|value| format!(" · {}%", (value * 100.0).round()))
                .unwrap_or_default();
            Some((format!("{}{}", orb_ui.status_message, pct), "info"))
        }
        "error" => Some(("Fae needs attention — open Messages".to_string(), "alert")),
        "stopping" | "stopped" => None,
        _ => match orb_ui.ui_mode {
            FaeUiState::Listening => Some(("Listening — let go to send".to_string(), "listen")),
            FaeUiState::Thinking => {
                // Long turns (NaN retries) can run 30s+: a ticking counter
                // reads as progress where a static label reads as a hang.
                let text = match thinking_secs {
                    Some(secs) if secs >= 5 => format!("Thinking — {secs}s"),
                    _ => "Thinking…".to_string(),
                };
                Some((text, "info"))
            }
            FaeUiState::Speaking => Some(("Speaking — tap ⌥ to interrupt".to_string(), "info")),
            FaeUiState::Quiescent => {
                if !orb_ui.has_user_message() {
                    // The one teaching moment that matters: shown until the
                    // user's first turn of the session.
                    Some((
                        "Hold Right ⌥ (or hold me) and speak — let go to send".to_string(),
                        "hint",
                    ))
                } else if hovering {
                    Some((
                        "Hold ⌥ or press-and-hold to talk · drag to move · right-click for menu"
                            .to_string(),
                        "hint",
                    ))
                } else {
                    None
                }
            }
        },
    }
}

fn refresh_pill(
    pill: &PillPanel,
    orb_ui: &OrbUiModel,
    hovering: bool,
    thinking_secs: Option<u64>,
    last: &mut Option<(String, String)>,
) {
    let content = pill_content(orb_ui, hovering, thinking_secs);
    let keyed = content
        .as_ref()
        .map(|(text, kind)| (text.clone(), (*kind).to_string()));
    if *last == keyed {
        return;
    }
    *last = keyed;
    let script = match content {
        Some((text, kind)) => {
            let text_json = serde_json::to_string(&text).unwrap_or_else(|_| "\"\"".to_string());
            format!("window.__setPill({text_json}, '{kind}');")
        }
        None => "window.__setPill(null);".to_string(),
    };
    if let Err(error) = pill.webview.evaluate_script(&script) {
        log::warn!("failed to refresh whisper pill: {error}");
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

fn is_messages_button_hit(position: PhysicalPosition<f64>, size: PhysicalSize<u32>) -> bool {
    let x = position.x as f32;
    let y = position.y as f32;
    let width = size.width as f32;
    let height = size.height as f32;
    let button_center = [width * 0.70, height * 0.72];
    let radius = width.min(height) * 0.14;
    let dx = x - button_center[0];
    let dy = y - button_center[1];
    dx * dx + dy * dy <= radius * radius
}

fn open_messages_panel(
    target: &tao::event_loop::EventLoopWindowTarget<UserEvent>,
    orb_ui: &OrbUiModel,
    panel_proxy: &tao::event_loop::EventLoopProxy<UserEvent>,
) -> Result<WebPanel, Box<dyn Error>> {
    let window = WindowBuilder::new()
        .with_title("Fae Messages")
        .with_inner_size(PhysicalSize::new(520, 680))
        .with_decorations(true)
        .with_always_on_top(true)
        .build(target)?;
    let html = messages_html(orb_ui);
    let proxy = panel_proxy.clone();
    let webview = build_webview_for_window(
        &window,
        WebViewBuilder::new()
            .with_html(html)
            .with_ipc_handler(move |request| {
                if let Err(error) = proxy.send_event(UserEvent::PanelAction(request.body().clone()))
                {
                    log::warn!("failed to forward messages panel IPC: {error}");
                }
            }),
    )?;
    Ok(WebPanel {
        kind: WebPanelKind::Messages,
        window,
        webview,
    })
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

fn refresh_messages_panels(web_panels: &[WebPanel], orb_ui: &OrbUiModel) {
    refresh_panel_kind(web_panels, WebPanelKind::Messages, messages_html(orb_ui));
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

fn messages_html(orb_ui: &OrbUiModel) -> String {
    // Status: a slim one-line chip. While waking it carries a progress bar;
    // once running it collapses to a quiet "● Ready · model" line; errors go
    // rowan-berry. The old full-width status card read as a permanent
    // dashboard widget and drowned the conversation.
    let status_chip = match orb_ui.status_phase.as_str() {
        "running" => format!(
            "<div class='chip ready'><span class='dot ok'></span>{}</div>",
            html_escape(&orb_ui.status_message)
        ),
        "error" => format!(
            "<div class='chip error'><span class='dot bad'></span>{}</div>",
            html_escape(&orb_ui.status_message)
        ),
        _ => {
            let pct = orb_ui
                .status_progress
                .map(|value| format!(" · {}%", (value * 100.0).round()))
                .unwrap_or_default();
            format!(
                "<div class='chip waking'><span class='dot warm'></span>{}{}<div class='progress'><div class='bar' style='width:{}'></div></div></div>",
                html_escape(&orb_ui.status_message),
                pct,
                orb_ui
                    .status_progress
                    .map(|value| format!("{}%", value * 100.0))
                    .unwrap_or_else(|| "0%".to_string())
            )
        }
    };

    let messages = if orb_ui.messages.is_empty() {
        "<div class='empty'><p class='empty-title'>Say hello</p>\
         <p>Hold Right&nbsp;⌥, speak, and let go to send.</p>\
         <p>You can also type below; Fae reads both the same way.</p></div>"
            .to_string()
    } else {
        orb_ui
            .messages
            .iter()
            .map(|message| {
                let role_class = match message.role.to_lowercase().as_str() {
                    "user" => "user",
                    "fae" | "assistant" => "fae",
                    "tool" => "tool",
                    _ => "other",
                };
                format!(
                    "<article class='msg {role_class}'><p>{text}</p></article>",
                    text = html_escape(&message.text)
                )
            })
            .collect::<Vec<_>>()
            .join("\n")
    };

    let listening = orb_ui.ui_mode == FaeUiState::Listening;
    let access_full = orb_ui.access != "assistant";
    let thinking = orb_ui.thinking.as_str();

    format!(
        r#"<!doctype html>
<html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'>
<style>
:root{{color-scheme:dark}}
html,body{{height:100%}}
body{{margin:0;background:radial-gradient(circle at 50% 0,#221F28,#0F1013 62%);color:#CEC4DC;font:14px -apple-system,BlinkMacSystemFont,Segoe UI,sans-serif}}
main{{display:flex;flex-direction:column;height:100vh;box-sizing:border-box;padding:14px 16px 12px;gap:10px}}
details{{border:1px solid rgba(180,168,196,.22);border-radius:12px;background:rgba(26,24,32,.7);overflow:hidden}}
summary{{cursor:pointer;list-style:none;display:flex;align-items:center;gap:8px;padding:9px 13px;font:600 12px -apple-system,BlinkMacSystemFont,sans-serif;color:#CEC4DC;user-select:none}}
summary::-webkit-details-marker{{display:none}}
summary .badge{{width:15px;height:15px;border-radius:50%;border:1px solid rgba(180,168,196,.5);display:inline-flex;align-items:center;justify-content:center;font:600 10px Georgia,serif;color:#CEC4DC;flex:none}}
summary .chev{{margin-left:auto;color:#9A90A8;font-size:10px;transition:transform .2s}}
details[open] summary .chev{{transform:rotate(180deg)}}
.help-body{{padding:2px 14px 12px;font-size:12px;line-height:1.55;color:#9A90A8}}
.help-body b{{color:#CEC4DC;font-weight:600}}
.help-body .eg{{color:#E6C05A}}
.chip{{display:flex;align-items:center;gap:8px;font-size:11px;color:#9A90A8;padding:0 2px;flex-wrap:wrap}}
.chip.error{{color:#C4788A}}
.dot{{width:7px;height:7px;border-radius:50%;flex:none}}
.dot.ok{{background:#8FB8A2}}
.dot.bad{{background:#C4788A}}
.dot.warm{{background:#E6C05A;animation:breathe 1.6s ease-in-out infinite}}
@keyframes breathe{{0%,100%{{opacity:.45}}50%{{opacity:1}}}}
.progress{{flex-basis:100%;height:4px;border-radius:99px;background:rgba(255,255,255,.08);overflow:hidden;margin-top:4px}}
.bar{{height:100%;background:linear-gradient(90deg,#C17F24,#D4A934)}}
#thread{{flex:1;overflow-y:auto;display:flex;flex-direction:column;gap:10px;padding:4px 2px}}
.msg{{border-radius:16px;padding:10px 14px;max-width:78%;border:1px solid rgba(255,255,255,.08);background:rgba(255,255,255,.05)}}
.msg.user{{margin-left:auto;background:#38476B;border-color:rgba(89,115,166,.5)}}
.msg.fae{{margin-right:auto;background:#3D334D;border-color:rgba(180,168,196,.25)}}
.msg.tool,.msg.other{{margin-right:auto;font-size:12px;color:#9A90A8}}
.msg p{{white-space:pre-wrap;line-height:1.5;margin:0;font-family:Georgia,'Times New Roman',serif;font-size:13px;color:#E8E2EE}}
.msg.user p{{color:#E6ECFA}}
.empty{{margin:auto;text-align:center;color:#9A90A8;font-size:13px;line-height:1.6;max-width:260px}}
.empty-title{{font-family:Georgia,serif;font-size:19px;color:#E8DED2;margin:0 0 6px}}
.composer{{display:flex;gap:8px;align-items:center}}
.composer input{{flex:1;border:1px solid rgba(180,168,196,.25);border-radius:9999px;background:#1A1820;color:#CEC4DC;padding:10px 16px;font:13px -apple-system,BlinkMacSystemFont,sans-serif;outline:none}}
.composer input:focus{{border-color:rgba(212,169,52,.55)}}
.round{{width:38px;height:38px;border-radius:50%;border:1px solid rgba(180,168,196,.3);background:#1A1820;color:#CEC4DC;cursor:pointer;display:inline-flex;align-items:center;justify-content:center;flex:none;padding:0}}
.round:hover{{background:#221F28}}
#mic{{border-color:rgba(122,155,142,.55)}}
#mic svg{{width:16px;height:16px;fill:#8FB8A2}}
#mic.listening{{border-color:#7A9B8E;box-shadow:0 0 0 0 rgba(122,155,142,.6);animation:ring 1.4s ease-out infinite}}
@keyframes ring{{0%{{box-shadow:0 0 0 0 rgba(122,155,142,.55)}}70%{{box-shadow:0 0 0 9px rgba(122,155,142,0)}}100%{{box-shadow:0 0 0 0 rgba(122,155,142,0)}}}}
#send{{border-color:rgba(212,169,52,.5);color:#E6C05A;font:600 15px -apple-system,sans-serif}}
#controls .controls-body{{display:flex;gap:28px;padding:4px 14px 12px}}
#controls label{{display:flex;flex-direction:column;gap:5px;font:600 10px -apple-system,sans-serif;letter-spacing:.1em;color:#9A90A8}}
#controls select{{border:1px solid rgba(180,168,196,.3);border-radius:8px;background:#1A1820;color:#CEC4DC;padding:5px 8px;font:12px -apple-system,sans-serif;outline:none}}
</style></head><body><main>
<details id='help'><summary><span class='badge'>?</span>Voice commands<span class='chev'>▼</span></summary>
<div class='help-body'>
<p><b>Hold Right ⌥</b> — or <b>press-and-hold the orb</b> — and speak; <b>let go to send</b>. The mic button below also listens (Fae sends when you pause).</p>
<p>Try: <span class='eg'>“What's on my calendar today?”</span> · <span class='eg'>“Remind me to call Mum at six.”</span> · <span class='eg'>“Search the web for tonight's weather.”</span></p>
<p><b>Drag</b> the orb to move it · <b>right-click</b> opens the menu · typing below works exactly like speaking.</p>
</div></details>
{status_chip}
<div id='thread'>{messages}</div>
<div class='composer'>
<button id='mic' class='round{mic_class}' title='Talk to Fae'><svg viewBox='0 0 16 16'><path d='M8 1a2.5 2.5 0 0 0-2.5 2.5v4a2.5 2.5 0 0 0 5 0v-4A2.5 2.5 0 0 0 8 1zm-4.5 6.5a.75.75 0 0 1 1.5 0 3 3 0 0 0 6 0 .75.75 0 0 1 1.5 0 4.5 4.5 0 0 1-3.75 4.44V14h1.5a.75.75 0 0 1 0 1.5h-4.5a.75.75 0 0 1 0-1.5h1.5v-2.06A4.5 4.5 0 0 1 3.5 7.5z'/></svg></button>
<input id='composer' placeholder='Message Fae…' autocomplete='off'>
<button id='send' class='round' title='Send'>↑</button>
</div>
<details id='controls'><summary>Controls<span class='chev'>▼</span></summary>
<div class='controls-body'>
<label>ACCESS<select id='access'>
<option value='full'{access_full_sel}>Everything</option>
<option value='assistant'{access_assist_sel}>Assistant (read-only)</option>
</select></label>
<label>THINKING<select id='thinking'>
<option value='fast'{think_fast}>Fast</option>
<option value='balanced'{think_balanced}>Balanced</option>
<option value='deep'{think_deep}>Deep</option>
</select></label>
</div></details>
<script>
(function() {{
  const post = (obj) => window.ipc.postMessage(JSON.stringify(obj));
  const input = document.getElementById('composer');
  const send = () => {{
    const text = input.value.trim();
    if (!text) return;
    post({{ type: 'send_text', text }});
    input.value = '';
  }};
  document.getElementById('send').addEventListener('click', send);
  input.addEventListener('keydown', (e) => {{ if (e.key === 'Enter') send(); }});
  document.getElementById('mic').addEventListener('click', () => post({{ type: 'menu', action: 'talk_toggle' }}));
  document.getElementById('access').addEventListener('change', (e) => post({{ type: 'set_access', value: e.target.value }}));
  document.getElementById('thinking').addEventListener('change', (e) => post({{ type: 'set_thinking', value: e.target.value }}));
  const thread = document.getElementById('thread');
  if (thread) thread.scrollTop = thread.scrollHeight;
}})();
</script>
</main></body></html>"#,
        status_chip = status_chip,
        messages = messages,
        mic_class = if listening { " listening" } else { "" },
        access_full_sel = if access_full { " selected" } else { "" },
        access_assist_sel = if access_full { "" } else { " selected" },
        think_fast = if thinking == "fast" { " selected" } else { "" },
        think_balanced = if thinking == "balanced" {
            " selected"
        } else {
            ""
        },
        think_deep = if thinking == "deep" { " selected" } else { "" },
    )
}

fn html_escape(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#39;")
}

fn open_browser_data_panel(
    target: &tao::event_loop::EventLoopWindowTarget<UserEvent>,
    orb_ui: &OrbUiModel,
) -> Result<WebPanel, Box<dyn Error>> {
    let window = WindowBuilder::new()
        .with_title("Fae Browser/Data Panel")
        .with_inner_size(PhysicalSize::new(920, 620))
        .with_decorations(true)
        .build(target)?;
    let html = browser_data_html(orb_ui);
    let webview = build_webview_for_window(&window, WebViewBuilder::new().with_html(html))?;
    Ok(WebPanel {
        kind: WebPanelKind::BrowserData,
        window,
        webview,
    })
}

fn browser_data_html(orb_ui: &OrbUiModel) -> String {
    let message_count = orb_ui.messages.len();
    let progress = orb_ui
        .status_progress
        .map(|value| format!("{}%", (value * 100.0).round()))
        .unwrap_or_else(|| "—".to_string());
    format!(
        r#"<!doctype html><html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'>
<style>body{{margin:0;background:#0F1013;color:#CEC4DC;font:15px -apple-system,BlinkMacSystemFont,Segoe UI,sans-serif}}main{{padding:28px;display:grid;gap:18px;grid-template-columns:repeat(auto-fit,minmax(240px,1fr))}}.card{{border:1px solid rgba(180,168,196,.25);border-radius:16px;padding:20px;background:#1A1820;box-shadow:0 20px 60px rgba(0,0,0,.32)}}h1{{grid-column:1/-1;margin:0 0 8px;font-size:28px;font-family:'Instrument Serif',Georgia,serif;color:#E8DED2}}.muted{{color:#9A90A8}}.chart{{height:120px;border-radius:12px;background:linear-gradient(90deg,#4A5D52,#7A9B8E,#C8D3D5);mask:radial-gradient(circle at 20% 60%,#000 0 18%,transparent 19%),linear-gradient(#000,#000)}}.video{{height:120px;border-radius:12px;background:radial-gradient(circle at 50% 50%,#3D334D,#221F28 65%,#0F1013);display:grid;place-items:center;color:#CEC4DC}}.metric{{font-size:34px;font-weight:700;color:#E6C05A}}</style></head><body><main>
<h1>Fae Browser/Data Panel</h1><p class='muted'>Orb-launched rich surface for charts, data, documents, and video. The orb remains the product UI.</p>
<section class='card'><h2>Runtime</h2><p class='muted'>{phase}</p><p>{message}</p><p class='metric'>{progress}</p></section>
<section class='card'><h2>Conversation</h2><p class='metric'>{message_count}</p><p class='muted'>recent messages held by the orb host</p></section>
<section class='card'><h2>Charts</h2><div class='chart'></div></section>
<section class='card'><h2>Video / Rich Media</h2><div class='video'>temporary rich panel</div></section>
</main></body></html>"#,
        phase = html_escape(&orb_ui.status_phase),
        message = html_escape(&orb_ui.status_message),
        progress = html_escape(&progress),
        message_count = message_count
    )
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
:root{{color-scheme:dark;--bg:#0F1013;--panel:#1A1820;--panel2:#221F28;--text:#CEC4DC;--soft:#9A90A8;--cream:#E8DED2;--gold:#E6C05A;--glen:#8FB8A2;--berry:#C4788A}}
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
input:focus,select:focus{{border-color:rgba(230,192,90,.68);box-shadow:0 0 0 3px rgba(230,192,90,.10)}}
input[type='checkbox']{{width:22px;height:22px;justify-self:end;accent-color:var(--gold)}}
.number-control{{display:grid;grid-template-columns:34px 1fr 34px;gap:6px;align-items:center}}
.stepper{{border-radius:10px;padding:8px 0;line-height:1;color:var(--cream);background:rgba(230,192,90,.10)}}
.unit{{font-size:11px;color:var(--soft);margin-top:4px;text-align:right}}
.info-grid{{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:14px}}
.info{{border:1px solid rgba(143,184,162,.24);border-radius:16px;padding:15px;background:#17201D}}
.info h3{{color:#DDE8E1}}.info .detail{{margin-top:8px;font-size:12px;color:#A9BFB4}}
button{{border:1px solid rgba(230,192,90,.48);border-radius:999px;background:rgba(230,192,90,.14);color:var(--gold);padding:8px 13px;font:12px -apple-system,BlinkMacSystemFont,Segoe UI,sans-serif;cursor:pointer}}
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
