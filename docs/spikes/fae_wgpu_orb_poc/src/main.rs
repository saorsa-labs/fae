mod menu;

use std::{error::Error, time::Instant};

use menu::{MenuAction, OrbMenu};
use tao::{
    dpi::{PhysicalPosition, PhysicalSize},
    event::{ElementState, Event, KeyEvent, MouseButton, WindowEvent},
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
}

#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
struct Uniforms {
    resolution: [f32; 2],
    time: f32,
    audio: f32,
    quality: f32,
    active: f32,
    _pad: [f32; 2],
}

impl Uniforms {
    fn new(size: PhysicalSize<u32>) -> Self {
        Self {
            resolution: [size.width as f32, size.height as f32],
            time: 0.0,
            audio: 0.0,
            quality: 1.0,
            active: 1.0,
            _pad: [0.0; 2],
        }
    }
}

struct WebPanel {
    window: Window,
    _webview: WebView,
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

    fn toggle_active(&mut self) {
        self.active = !self.active;
        self.uniforms.active = if self.active { 1.0 } else { 0.0 };
    }

    fn update(&mut self) {
        if self.active {
            let time = self.start.elapsed().as_secs_f32();
            let phrase = (0.5 + 0.5 * (time * 2.7).sin()).powf(2.0);
            let tremor = 0.5 + 0.5 * (time * 19.0).sin();
            self.uniforms.time = time;
            self.uniforms.audio = (0.10 + phrase * 0.55 + tremor * 0.08).clamp(0.0, 1.0);
        } else {
            self.uniforms.audio = 0.0;
        }
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
    let mut event_loop_builder = EventLoopBuilder::<UserEvent>::with_user_event();
    let event_loop = event_loop_builder.build();
    let proxy = event_loop.create_proxy();
    muda::MenuEvent::set_event_handler(Some(move |event| {
        if let Err(error) = proxy.send_event(UserEvent::Menu(event)) {
            log::warn!("failed to forward menu event: {error}");
        }
    }));

    let window = WindowBuilder::new()
        .with_title("Fae Orb")
        .with_inner_size(PhysicalSize::new(420, 420))
        .with_resizable(false)
        .with_decorations(false)
        .with_transparent(true)
        .with_always_on_top(true)
        .build(&event_loop)?;
    let window: &'static Window = Box::leak(Box::new(window));
    let orb_menu = OrbMenu::new()?;
    let mut state = pollster::block_on(State::new(window))?;
    let mut cursor_position = PhysicalPosition::new(210.0, 210.0);
    let mut web_panels: Vec<WebPanel> = Vec::new();

    event_loop.run(move |event, target, control_flow| {
        *control_flow = if state.active {
            ControlFlow::Poll
        } else {
            ControlFlow::Wait
        };

        match event {
            Event::UserEvent(UserEvent::Menu(event)) => {
                if let Some(action) = OrbMenu::action_for_event(&event) {
                    handle_menu_action(
                        action,
                        target,
                        &mut state,
                        window,
                        &mut web_panels,
                        control_flow,
                    );
                    window.request_redraw();
                }
            }
            Event::WindowEvent {
                event, window_id, ..
            } if window_id == window.id() => match event {
                WindowEvent::CloseRequested => *control_flow = ControlFlow::Exit,
                WindowEvent::Resized(size) => {
                    state.resize(size);
                    window.request_redraw();
                }
                WindowEvent::CursorMoved { position, .. } => {
                    cursor_position = position;
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
                    if let Err(error) = window.drag_window() {
                        log::warn!("failed to start orb drag: {error}");
                    }
                }
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
            Event::MainEventsCleared if state.active => {
                window.request_redraw();
            }
            _ => {}
        }
    });
}

fn handle_menu_action(
    action: MenuAction,
    target: &tao::event_loop::EventLoopWindowTarget<UserEvent>,
    state: &mut State,
    window: &Window,
    web_panels: &mut Vec<WebPanel>,
    control_flow: &mut ControlFlow,
) {
    match action {
        MenuAction::OpenBrowserDataPanel | MenuAction::OpenWorkWithFae => {
            match open_browser_data_panel(target) {
                Ok(panel) => web_panels.push(panel),
                Err(error) => log::error!("failed to open browser/data panel: {error}"),
            }
        }
        MenuAction::HideFae => {
            state.active = false;
            state.uniforms.active = 0.0;
            window.set_visible(false);
        }
        MenuAction::Quit => *control_flow = ControlFlow::Exit,
        MenuAction::Stop => {
            state.active = false;
            state.uniforms.active = 0.0;
        }
        other => {
            log::info!("stubbed Fae menu action: {other:?}");
        }
    }
}

fn open_browser_data_panel(
    target: &tao::event_loop::EventLoopWindowTarget<UserEvent>,
) -> Result<WebPanel, Box<dyn Error>> {
    let window = WindowBuilder::new()
        .with_title("Fae Browser/Data Panel")
        .with_inner_size(PhysicalSize::new(920, 620))
        .with_decorations(true)
        .build(target)?;
    let html = r#"
<!doctype html>
<html>
<head>
<meta charset='utf-8'>
<meta name='viewport' content='width=device-width, initial-scale=1'>
<style>
body{margin:0;background:#100905;color:#ffe2a0;font:15px -apple-system,BlinkMacSystemFont,Segoe UI,sans-serif;}
main{padding:28px;display:grid;gap:18px;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));}
.card{border:1px solid rgba(255,210,110,.28);border-radius:22px;padding:20px;background:linear-gradient(135deg,rgba(255,185,60,.12),rgba(255,255,255,.04));box-shadow:0 20px 60px rgba(0,0,0,.32)}
h1{grid-column:1/-1;margin:0 0 8px;font-size:28px}.muted{color:rgba(255,255,255,.68)}
.chart{height:120px;border-radius:16px;background:linear-gradient(90deg,#ff5a12,#ffb92e,#ffe59a);mask:radial-gradient(circle at 20% 60%,#000 0 18%,transparent 19%),linear-gradient(#000,#000);}
.video{height:120px;border-radius:16px;background:radial-gradient(circle at 50% 50%,#ffbe37,#301305 65%,#120704);display:grid;place-items:center;color:#fff1bf}
</style>
</head>
<body><main>
<h1>Fae Browser/Data Panel</h1>
<p class='muted'>wry webview proof: charts, browser data, and video belong here — not in the orb surface.</p>
<section class='card'><h2>Charts</h2><div class='chart'></div></section>
<section class='card'><h2>Video / Rich Media</h2><div class='video'>video/data surface</div></section>
<section class='card'><h2>Tools & Permissions</h2><p class='muted'>Menu actions are stubbed in this POC and ready to wire to Fae core.</p></section>
</main></body></html>
"#;
    let webview = WebViewBuilder::new().with_html(html).build(&window)?;
    Ok(WebPanel {
        window,
        _webview: webview,
    })
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
        let _ = (menu, window, position);
        log::warn!("context menu popup is only wired for macOS in this POC");
    }
}
