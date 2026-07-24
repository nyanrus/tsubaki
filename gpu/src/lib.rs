//! Browser-only WebGPU binding for Tsubaki, kept as its own crate rather than
//! folded into `kernel/` -- that crate is deliberately raw linear memory,
//! loaded synchronously via `new WebAssembly.Instance(module, {})` with no
//! imports at all (see preload.js). wgpu's web backend fundamentally needs
//! JS interop (navigator.gpu.requestAdapter/requestDevice are async Promise
//! calls, buffer readback is async too), which only works through
//! wasm-bindgen -- a different wasm module shape (imports, a JS glue file,
//! Promise-returning exports) that would be a strange fit bolted onto the
//! existing synchronous kernel. Two small modules, each honest about what
//! it is, beat one module pretending to be both.
//!
//! Resources (buffers, pipelines) are handed to JS as opaque `u32` handles
//! -- wasm-bindgen can't hand JS a live Rust reference across separate
//! calls, and handles are the standard idiom for that. The caller owns the
//! handle's lifetime (create/destroy explicitly); this module only adds a
//! content-hash dedup on top of `create_pipeline` so an accidental "create
//! the same shader every frame" caller doesn't pay a recompile each time.
use std::cell::RefCell;
use std::collections::HashMap;
use std::hash::{Hash, Hasher};
use wasm_bindgen::prelude::*;

#[wasm_bindgen(start)]
pub fn start() {
    console_error_panic_hook::set_once();
}

/// 4x MSAA -- the only sample count WebGPU actually guarantees support for
/// (the spec doesn't require 2x/8x/16x; browsers universally support 4x).
/// Real multisampling of triangle edges, layered on top of (not replacing)
/// the fwidth()-based analytic AA callers already do inside their own WGSL
/// for ribbon/circle edges -- that trick smooths a shape's OWN silhouette
/// against its fragment shader's alpha falloff, but has nothing to say
/// about the triangle-rasterization edges MSAA targets (e.g. two adjacent
/// ribbon segments meeting at a slight angle). Both together look
/// noticeably better than either alone.
const MSAA_SAMPLES: u32 = 4;

/// What a `@binding(i)` slot in a pipeline's layout actually is. The first
/// three are buffer-backed (created via `create_buffer`); `Texture`/
/// `Sampler` are the piece image-based rendering (a baked text label, a
/// diagram, a lookup table -- anything that isn't a flat numeric buffer)
/// needs, created via `create_texture`/`create_sampler` instead.
#[derive(Clone, Copy, PartialEq, Eq, Hash)]
enum BindingKind {
    StorageRead,
    StorageReadWrite,
    Uniform,
    Texture,
    Sampler,
}

impl BindingKind {
    fn parse(s: &str) -> Result<Self, JsValue> {
        match s {
            "storage-read" => Ok(BindingKind::StorageRead),
            "storage-read-write" => Ok(BindingKind::StorageReadWrite),
            "uniform" => Ok(BindingKind::Uniform),
            "texture" => Ok(BindingKind::Texture),
            "sampler" => Ok(BindingKind::Sampler),
            other => Err(JsValue::from_str(&format!(
                "unknown binding kind {other:?} -- expected \"storage-read\", \"storage-read-write\", \"uniform\", \"texture\", or \"sampler\""
            ))),
        }
    }

    /// Only the three buffer-backed kinds have a meaningful `BufferUsages`
    /// -- `create_buffer` calls this and rejects `Texture`/`Sampler`
    /// up front, pointing at the function that actually creates those.
    fn buffer_usages(self) -> Result<wgpu::BufferUsages, JsValue> {
        match self {
            BindingKind::StorageRead | BindingKind::StorageReadWrite => {
                Ok(wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::COPY_SRC)
            }
            BindingKind::Uniform => Ok(wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST),
            BindingKind::Texture | BindingKind::Sampler => Err(JsValue::from_str(
                "create_buffer: \"texture\"/\"sampler\" aren't buffers -- use create_texture/create_sampler instead",
            )),
        }
    }

    fn layout_entry(self, binding: u32, visibility: wgpu::ShaderStages) -> wgpu::BindGroupLayoutEntry {
        let ty = match self {
            BindingKind::StorageRead => wgpu::BindingType::Buffer {
                ty: wgpu::BufferBindingType::Storage { read_only: true },
                has_dynamic_offset: false,
                min_binding_size: None,
            },
            BindingKind::StorageReadWrite => wgpu::BindingType::Buffer {
                ty: wgpu::BufferBindingType::Storage { read_only: false },
                has_dynamic_offset: false,
                min_binding_size: None,
            },
            BindingKind::Uniform => wgpu::BindingType::Buffer {
                ty: wgpu::BufferBindingType::Uniform,
                has_dynamic_offset: false,
                min_binding_size: None,
            },
            BindingKind::Texture => wgpu::BindingType::Texture {
                sample_type: wgpu::TextureSampleType::Float { filterable: true },
                view_dimension: wgpu::TextureViewDimension::D2,
                multisampled: false,
            },
            BindingKind::Sampler => wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
        };
        wgpu::BindGroupLayoutEntry { binding, visibility, ty, count: None }
    }
}

struct BufferEntry {
    buffer: wgpu::Buffer,
    size: u64,
}

struct TextureEntry {
    texture: wgpu::Texture,
    view: wgpu::TextureView,
}

/// The persistent multisampled color target every render pass draws into --
/// created once in `configure_canvas` (sized to the canvas), reused every
/// frame. Kept as (texture, view) rather than just the view, same reason
/// `TextureEntry` keeps both: nothing here relies on a view implicitly
/// keeping its texture alive.
struct MsaaTarget {
    #[allow(dead_code)]
    texture: wgpu::Texture,
    view: wgpu::TextureView,
}

fn parse_topology(s: &str) -> Result<wgpu::PrimitiveTopology, JsValue> {
    match s {
        "triangle-list" => Ok(wgpu::PrimitiveTopology::TriangleList),
        "triangle-strip" => Ok(wgpu::PrimitiveTopology::TriangleStrip),
        "line-list" => Ok(wgpu::PrimitiveTopology::LineList),
        "line-strip" => Ok(wgpu::PrimitiveTopology::LineStrip),
        "point-list" => Ok(wgpu::PrimitiveTopology::PointList),
        other => Err(JsValue::from_str(&format!(
            "unknown topology {other:?} -- expected \"triangle-list\", \"triangle-strip\", \"line-list\", \"line-strip\", or \"point-list\""
        ))),
    }
}

fn parse_blend(s: &str) -> Result<wgpu::BlendState, JsValue> {
    match s {
        "replace" => Ok(wgpu::BlendState::REPLACE),
        "alpha" => Ok(wgpu::BlendState::ALPHA_BLENDING),
        "premultiplied-alpha" => Ok(wgpu::BlendState::PREMULTIPLIED_ALPHA_BLENDING),
        other => Err(JsValue::from_str(&format!(
            "unknown blend {other:?} -- expected \"replace\", \"alpha\", or \"premultiplied-alpha\""
        ))),
    }
}

struct PipelineEntry {
    pipeline: wgpu::ComputePipeline,
    bind_group_layout: wgpu::BindGroupLayout,
    binding_kinds: Vec<BindingKind>,
}

struct RenderPipelineEntry {
    pipeline: wgpu::RenderPipeline,
    bind_group_layout: wgpu::BindGroupLayout,
    binding_kinds: Vec<BindingKind>,
}

struct GpuState {
    instance: wgpu::Instance,
    adapter: wgpu::Adapter,
    device: wgpu::Device,
    queue: wgpu::Queue,
    buffers: HashMap<u32, BufferEntry>,
    textures: HashMap<u32, TextureEntry>,
    samplers: HashMap<u32, wgpu::Sampler>,
    pipelines: HashMap<u32, PipelineEntry>,
    pipeline_cache: HashMap<u64, u32>,
    render_pipelines: HashMap<u32, RenderPipelineEntry>,
    render_pipeline_cache: HashMap<u64, u32>,
    surface: Option<wgpu::Surface<'static>>,
    surface_format: Option<wgpu::TextureFormat>,
    msaa_target: Option<MsaaTarget>,
    current_frame: Option<FrameState>,
    next_handle: u32,
}

/// One open frame between `begin_frame` and `end_frame`: the surface
/// texture + view (used only as the MSAA resolve target now, not drawn
/// into directly -- see `MsaaTarget`) and the command encoder every
/// `draw_frame` call adds a render pass to. Kept alive across separate
/// wasm-bindgen calls (not just one function) so several draws can compose
/// one frame without each clearing and presenting on its own.
struct FrameState {
    surface_texture: wgpu::SurfaceTexture,
    surface_view: wgpu::TextureView,
    encoder: wgpu::CommandEncoder,
}

/// Resolves a handle to whatever it actually is (buffer, texture view, or
/// sampler) for building a `BindGroupEntry` -- `dispatch`/`render` don't
/// need to know or care which kind of resource each handle in their list
/// is; the pipeline's own layout (built from the `binding_kinds` passed to
/// `create_pipeline`/`create_render_pipeline`) is what actually constrains
/// that, same as real WebGPU.
fn resolve_binding_resource(gpu: &GpuState, handle: u32) -> Result<wgpu::BindingResource<'_>, JsValue> {
    if let Some(entry) = gpu.buffers.get(&handle) {
        return Ok(entry.buffer.as_entire_binding());
    }
    if let Some(entry) = gpu.textures.get(&handle) {
        return Ok(wgpu::BindingResource::TextureView(&entry.view));
    }
    if let Some(sampler) = gpu.samplers.get(&handle) {
        return Ok(wgpu::BindingResource::Sampler(sampler));
    }
    Err(JsValue::from_str(&format!("unknown resource handle {handle}")))
}

impl GpuState {
    fn alloc_handle(&mut self) -> u32 {
        let h = self.next_handle;
        self.next_handle += 1;
        h
    }
}

thread_local! {
    static GPU: RefCell<Option<GpuState>> = RefCell::new(None);
}

fn with_gpu<T>(f: impl FnOnce(&mut GpuState) -> Result<T, JsValue>) -> Result<T, JsValue> {
    GPU.with(|cell| {
        let mut borrow = cell.borrow_mut();
        let gpu = borrow
            .as_mut()
            .ok_or_else(|| JsValue::from_str("gpu_init() must be awaited before calling into tsubaki-gpu"))?;
        f(gpu)
    })
}

/// Clones out (device, queue) without holding the `RefCell` borrow -- needed
/// before any `.await`, since another exported call could run while this one
/// is suspended (single-threaded, but cooperatively scheduled by the JS
/// event loop) and would otherwise conflict with a live borrow.
fn cloned_device_queue() -> Result<(wgpu::Device, wgpu::Queue), JsValue> {
    with_gpu(|gpu| Ok((gpu.device.clone(), gpu.queue.clone())))
}

fn content_hash(parts: &[&str], binding_kinds: &[BindingKind]) -> u64 {
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    parts.hash(&mut hasher);
    binding_kinds.hash(&mut hasher);
    hasher.finish()
}

/// Requests a GPU adapter + device from the browser -- await this once
/// before any other call here; there's no synchronous adapter/device
/// acquisition in WebGPU at all. `power_preference` is `"low-power"`,
/// `"high-performance"`, or omitted/anything else for the browser's own
/// default. Returns the adapter actually granted (name/backend/device
/// type/driver), since the browser -- not this code -- makes the real
/// choice and callers may want to know what they got, or show it.
///
/// Prefers real WebGPU but transparently falls back to WebGL2 (via wgpu's
/// own `gles` backend) wherever WebGPU isn't available -- Safari without
/// the flag, older browsers, some headless/CI environments. Uses wgpu's
/// own blessed helper (`new_instance_with_webgpu_detection`) rather than
/// hand-rolling the check: it probes `navigator.gpu` AND actually tries
/// `requestAdapter()` (some environments expose the property but still
/// fail to grant an adapter), then builds an `Instance` with
/// `BROWSER_WEBGPU` only if that really succeeded -- WebGL is otherwise
/// the only backend offered, so there's no chance of silently landing on
/// a half-working WebGPU path. The SAME `Instance` is kept in `GpuState`
/// and reused by `configure_canvas` (never a fresh `Instance::default()`
/// there) specifically so a canvas surface always matches whichever
/// backend detection actually picked here.
///
/// `canvas` is optional and ONLY needed to make WebGL fallback actually
/// work: unlike WebGPU, a browser WebGL context is intrinsically tied to a
/// canvas -- wgpu's `gles` web backend literally cannot enumerate an
/// adapter without one (`RequestAdapterOptions::compatible_surface` is
/// "strictly required" for WebGL, per wgpu's own docs), so a canvas-less
/// call here can only ever succeed via WebGPU. Compute-only callers with
/// no canvas at all can keep passing `None` -- WebGPU-or-nothing there is
/// an intrinsic browser limitation, not a choice this crate is making.
/// Callers that DO have a canvas should pass it here (the same canvas
/// `configure_canvas` will be called with next) to get real WebGL
/// fallback. This is a temporary surface used only to probe for an
/// adapter -- `configure_canvas` creates its own (`canvas.getContext(...)`
/// is idempotent per context type, so this doesn't conflict).
#[wasm_bindgen]
pub async fn gpu_init(power_preference: Option<String>, canvas: Option<web_sys::HtmlCanvasElement>) -> Result<JsValue, JsValue> {
    let instance = wgpu::util::new_instance_with_webgpu_detection(wgpu::InstanceDescriptor {
        backends: wgpu::Backends::BROWSER_WEBGPU | wgpu::Backends::GL,
        ..wgpu::InstanceDescriptor::new_without_display_handle()
    })
    .await;
    let power_preference = match power_preference.as_deref() {
        Some("high-performance") => wgpu::PowerPreference::HighPerformance,
        Some("low-power") => wgpu::PowerPreference::LowPower,
        _ => wgpu::PowerPreference::default(),
    };
    let adapter_probe_surface =
        canvas.map(|c| instance.create_surface(wgpu::SurfaceTarget::Canvas(c))).transpose().map_err(|e| {
            JsValue::from_str(&format!("gpu_init: create_surface for adapter probing failed: {e}"))
        })?;
    let adapter = instance
        .request_adapter(&wgpu::RequestAdapterOptions {
            power_preference,
            compatible_surface: adapter_probe_surface.as_ref(),
            ..Default::default()
        })
        .await
        .map_err(|e| JsValue::from_str(&format!("no GPU adapter: {e}")))?;
    let info = adapter.get_info();
    // `required_limits: adapter.limits()` -- exactly what the GRANTED
    // adapter actually reports, not `Limits::default()`'s (WebGPU-shaped)
    // assumptions. Real, measured difference: a WebGL2/gles adapter
    // reports `max_compute_workgroups_per_dimension: 0` (WebGL2 has no
    // compute stage at all, not a smaller one) -- requesting the WebGPU
    // default of 65535 there made `request_device` fail outright, even
    // though nothing had tried to actually dispatch a compute pass yet.
    // Compute calls against a WebGL-backed device still fail later, at
    // the real call site -- honestly, not silently downgraded here.
    let (device, queue) = adapter
        .request_device(&wgpu::DeviceDescriptor { required_limits: adapter.limits(), ..Default::default() })
        .await
        .map_err(|e| JsValue::from_str(&format!("device request failed: {e}")))?;

    GPU.with(|cell| {
        *cell.borrow_mut() = Some(GpuState {
            instance,
            adapter,
            device,
            queue,
            buffers: HashMap::new(),
            textures: HashMap::new(),
            samplers: HashMap::new(),
            pipelines: HashMap::new(),
            pipeline_cache: HashMap::new(),
            render_pipelines: HashMap::new(),
            render_pipeline_cache: HashMap::new(),
            surface: None,
            surface_format: None,
            msaa_target: None,
            current_frame: None,
            next_handle: 1,
        })
    });

    let obj = js_sys::Object::new();
    js_sys::Reflect::set(&obj, &"name".into(), &JsValue::from_str(&info.name))?;
    js_sys::Reflect::set(&obj, &"backend".into(), &JsValue::from_str(&format!("{:?}", info.backend)))?;
    js_sys::Reflect::set(&obj, &"deviceType".into(), &JsValue::from_str(&format!("{:?}", info.device_type)))?;
    js_sys::Reflect::set(&obj, &"driver".into(), &JsValue::from_str(&info.driver))?;
    Ok(obj.into())
}

/// Resolves once, whenever the current device is lost (context loss, a
/// crashed GPU process, a browser tab backgrounding-related reclaim...).
/// Await this in the background (don't block on it) and call `gpu_init`
/// again on resolution to recover -- there is no way to "resume" a lost
/// wgpu device, only replace it.
#[wasm_bindgen]
pub async fn gpu_on_device_lost() -> Result<String, JsValue> {
    let (device, _queue) = cloned_device_queue()?;
    let (tx, rx) = futures_channel::oneshot::channel::<String>();
    // `set_device_lost_callback` requires `Send`; an `Rc` capture wouldn't
    // satisfy that (Rc is unconditionally !Send, even on single-threaded
    // wasm32 -- the bound is checked structurally, not per-target), so this
    // needs an `Arc<Mutex<_>>` even though there's really only one thread.
    let tx = std::sync::Arc::new(std::sync::Mutex::new(Some(tx)));
    device.set_device_lost_callback(move |reason, message| {
        if let Some(tx) = tx.lock().unwrap().take() {
            let _ = tx.send(format!("{reason:?}: {message}"));
        }
    });
    rx.await.map_err(|_| JsValue::from_str("gpu_on_device_lost: sender dropped"))
}

/// Allocates a GPU buffer of `size_bytes`, usable as `kind` ("storage-read",
/// "storage-read-write", or "uniform" -- matching WGSL's own storage
/// classes). Returns an opaque handle; pass it to `write_buffer`/
/// `read_buffer`/`dispatch`/`destroy_buffer`.
#[wasm_bindgen]
pub fn create_buffer(size_bytes: u32, kind: String) -> Result<u32, JsValue> {
    let binding_kind = BindingKind::parse(&kind)?;
    let usage = binding_kind.buffer_usages()?;
    with_gpu(|gpu| {
        let buffer = gpu.device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("tsubaki-gpu buffer"),
            size: size_bytes as u64,
            usage,
            mapped_at_creation: false,
        });
        let handle = gpu.alloc_handle();
        gpu.buffers.insert(handle, BufferEntry { buffer, size: size_bytes as u64 });
        Ok(handle)
    })
}

/// Uploads `data` to `handle` at byte offset 0 -- plain `queue.write_buffer`,
/// which is NOT async on the browser's own WebGPU (only adapter/device
/// acquisition and readback are); safe to call every frame.
#[wasm_bindgen]
pub fn write_buffer(handle: u32, data: Vec<f32>) -> Result<(), JsValue> {
    with_gpu(|gpu| {
        let entry = gpu
            .buffers
            .get(&handle)
            .ok_or_else(|| JsValue::from_str(&format!("write_buffer: unknown buffer handle {handle}")))?;
        gpu.queue.write_buffer(&entry.buffer, 0, bytemuck::cast_slice(&data));
        Ok(())
    })
}

/// Reads `handle` back via a staging buffer + `mapAsync` -- WebGPU has no
/// synchronous buffer readback at all, by design, so this is the one buffer
/// operation that must be awaited.
#[wasm_bindgen]
pub async fn read_buffer(handle: u32) -> Result<Vec<f32>, JsValue> {
    let (device, queue, size) = with_gpu(|gpu| {
        let entry = gpu
            .buffers
            .get(&handle)
            .ok_or_else(|| JsValue::from_str(&format!("read_buffer: unknown buffer handle {handle}")))?;
        Ok((gpu.device.clone(), gpu.queue.clone(), entry.size))
    })?;
    let source = with_gpu(|gpu| Ok(gpu.buffers.get(&handle).unwrap().buffer.clone()))?;

    let staging = device.create_buffer(&wgpu::BufferDescriptor {
        label: Some("tsubaki-gpu read staging"),
        size,
        usage: wgpu::BufferUsages::MAP_READ | wgpu::BufferUsages::COPY_DST,
        mapped_at_creation: false,
    });
    let mut encoder = device.create_command_encoder(&wgpu::CommandEncoderDescriptor {
        label: Some("tsubaki-gpu read encoder"),
    });
    encoder.copy_buffer_to_buffer(&source, 0, &staging, 0, size);
    queue.submit(Some(encoder.finish()));

    let slice = staging.slice(..);
    let (tx, rx) = futures_channel::oneshot::channel();
    slice.map_async(wgpu::MapMode::Read, move |res| {
        let _ = tx.send(res);
    });
    rx.await
        .map_err(|_| JsValue::from_str("read_buffer: map_async callback dropped"))?
        .map_err(|e| JsValue::from_str(&format!("buffer map failed: {e}")))?;

    let data = slice
        .get_mapped_range()
        .map_err(|e| JsValue::from_str(&format!("get_mapped_range failed: {e}")))?;
    let result: Vec<f32> = bytemuck::cast_slice(&data).to_vec();
    drop(data);
    staging.unmap();
    Ok(result)
}

/// Destroys a buffer immediately (not just drops a reference -- releases
/// the underlying GPU allocation right away, deterministically).
#[wasm_bindgen]
pub fn destroy_buffer(handle: u32) -> Result<(), JsValue> {
    with_gpu(|gpu| {
        if let Some(entry) = gpu.buffers.remove(&handle) {
            entry.buffer.destroy();
        }
        Ok(())
    })
}

/// Uploads `rgba` (raw RGBA8, exactly `width*height*4` bytes -- e.g.
/// straight out of a 2-D canvas' `getImageData().data`) as a new 2-D
/// texture, immediately (`queue.write_texture` isn't async, same as
/// `write_buffer`). This is the piece the buffer-only binding model was
/// missing for anything image-based -- a baked text label, a diagram, a
/// lookup table -- not just a growing list of numeric buffer kinds. Bind
/// with kind `"texture"` in `create_pipeline`/`create_render_pipeline`.
#[wasm_bindgen]
pub fn create_texture(width: u32, height: u32, rgba: Vec<u8>) -> Result<u32, JsValue> {
    let expected = width as u64 * height as u64 * 4;
    if rgba.len() as u64 != expected {
        return Err(JsValue::from_str(&format!(
            "create_texture: expected {expected} bytes ({width}x{height}x4 RGBA8), got {}",
            rgba.len()
        )));
    }
    with_gpu(|gpu| {
        let size = wgpu::Extent3d { width, height, depth_or_array_layers: 1 };
        let texture = gpu.device.create_texture(&wgpu::TextureDescriptor {
            label: Some("tsubaki-gpu texture"),
            size,
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: wgpu::TextureFormat::Rgba8Unorm,
            usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
            view_formats: &[],
        });
        gpu.queue.write_texture(
            wgpu::TexelCopyTextureInfo {
                texture: &texture,
                mip_level: 0,
                origin: wgpu::Origin3d::ZERO,
                aspect: wgpu::TextureAspect::All,
            },
            &rgba,
            wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(width * 4), rows_per_image: Some(height) },
            size,
        );
        let view = texture.create_view(&wgpu::TextureViewDescriptor::default());
        let handle = gpu.alloc_handle();
        gpu.textures.insert(handle, TextureEntry { texture, view });
        Ok(handle)
    })
}

/// Destroys a texture immediately, same as `destroy_buffer`.
#[wasm_bindgen]
pub fn destroy_texture(handle: u32) -> Result<(), JsValue> {
    with_gpu(|gpu| {
        if let Some(entry) = gpu.textures.remove(&handle) {
            entry.texture.destroy();
        }
        Ok(())
    })
}

/// Creates a sampler; `filter` is `"nearest"` (crisp, blocky -- right for a
/// baked-text or pixel-art texture sampled at its native size) or
/// `"linear"` (smoothed). Address mode is always clamp-to-edge -- the
/// common case for a UI-ish texture, not a tiling one; nothing has asked
/// for tiling yet. Bind with kind `"sampler"`.
#[wasm_bindgen]
pub fn create_sampler(filter: String) -> Result<u32, JsValue> {
    let mode = match filter.as_str() {
        "nearest" => wgpu::FilterMode::Nearest,
        "linear" => wgpu::FilterMode::Linear,
        other => {
            return Err(JsValue::from_str(&format!(
                "create_sampler: unknown filter {other:?} -- expected \"nearest\" or \"linear\""
            )))
        }
    };
    with_gpu(|gpu| {
        let sampler = gpu.device.create_sampler(&wgpu::SamplerDescriptor {
            label: Some("tsubaki-gpu sampler"),
            address_mode_u: wgpu::AddressMode::ClampToEdge,
            address_mode_v: wgpu::AddressMode::ClampToEdge,
            address_mode_w: wgpu::AddressMode::ClampToEdge,
            mag_filter: mode,
            min_filter: mode,
            mipmap_filter: wgpu::MipmapFilterMode::Nearest,
            ..Default::default()
        });
        let handle = gpu.alloc_handle();
        gpu.samplers.insert(handle, sampler);
        Ok(handle)
    })
}

/// Destroys a sampler immediately, same as `destroy_buffer`.
#[wasm_bindgen]
pub fn destroy_sampler(handle: u32) -> Result<(), JsValue> {
    with_gpu(|gpu| {
        gpu.samplers.remove(&handle);
        Ok(())
    })
}

/// Compiles `wgsl` (must define a `@compute fn <entry_point>(...)`) into a
/// pipeline whose bind group layout is `binding_kinds`, in binding order
/// (index 0 = `@binding(0)`, etc, each `"storage-read"`/
/// `"storage-read-write"`/`"uniform"`). Identical (wgsl, entry_point,
/// binding_kinds) reuses the previously-compiled pipeline instead of
/// recompiling -- calling this every frame with the same shader is fine, it
/// just returns the cached handle.
///
/// Bad WGSL (syntax/type errors) is caught via `ShaderModule::
/// get_compilation_info()` and returned as a real rejected Promise with the
/// message text -- deliberately NOT via WebGPU error scopes
/// (`push_error_scope`/`pop_error_scope`) or `on_uncaptured_error`, even
/// though those are the spec's general mechanism: both route through wgpu
/// 30.0.0's `Error::from_js`, which only knows `GPUValidationError` and
/// `GPUOutOfMemoryError` and PANICS (crashing the whole wasm module, not
/// just this call) on any other WebGPU error class -- confirmed by
/// triggering it in real headless Chrome while building this, where the
/// browser reported a `GPUInternalError` (a legitimate WebGPU error class,
/// just one this wgpu version's conversion doesn't handle). Given that,
/// this only catches shader-source errors, not later-stage errors (e.g. a
/// bind group layout mismatched against what the shader actually declares)
/// -- a real, disclosed gap, not a promise this fully covers "GPU errors."
#[wasm_bindgen]
pub async fn create_pipeline(
    wgsl: String,
    entry_point: String,
    binding_kinds: Vec<String>,
) -> Result<u32, JsValue> {
    let binding_kinds: Vec<BindingKind> =
        binding_kinds.iter().map(|s| BindingKind::parse(s)).collect::<Result<_, _>>()?;
    let key = content_hash(&[&wgsl, &entry_point], &binding_kinds);
    if let Some(handle) = with_gpu(|gpu| Ok(gpu.pipeline_cache.get(&key).copied()))? {
        return Ok(handle);
    }

    let (device, _queue) = cloned_device_queue()?;
    let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
        label: Some("tsubaki-gpu shader"),
        source: wgpu::ShaderSource::Wgsl(wgsl.into()),
    });

    let compilation_errors: Vec<String> = shader
        .get_compilation_info()
        .await
        .messages
        .into_iter()
        .filter(|m| m.message_type == wgpu::CompilationMessageType::Error)
        .map(|m| m.message)
        .collect();
    if !compilation_errors.is_empty() {
        return Err(JsValue::from_str(&format!(
            "create_pipeline: WGSL error(s): {}",
            compilation_errors.join("; ")
        )));
    }

    let layout_entries: Vec<_> = binding_kinds
        .iter()
        .enumerate()
        .map(|(i, k)| k.layout_entry(i as u32, wgpu::ShaderStages::COMPUTE))
        .collect();
    let bind_group_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
        label: Some("tsubaki-gpu bind group layout"),
        entries: &layout_entries,
    });
    let pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
        label: Some("tsubaki-gpu pipeline layout"),
        bind_group_layouts: &[Some(&bind_group_layout)],
        immediate_size: 0,
    });
    let pipeline = device.create_compute_pipeline(&wgpu::ComputePipelineDescriptor {
        label: Some("tsubaki-gpu pipeline"),
        layout: Some(&pipeline_layout),
        module: &shader,
        entry_point: Some(&entry_point),
        compilation_options: Default::default(),
        cache: None,
    });

    with_gpu(|gpu| {
        let handle = gpu.alloc_handle();
        gpu.pipelines.insert(handle, PipelineEntry { pipeline, bind_group_layout, binding_kinds });
        gpu.pipeline_cache.insert(key, handle);
        Ok(handle)
    })
}

/// Destroys a pipeline (and drops it from the content-hash cache, so a
/// later `create_pipeline` with the same source genuinely recompiles rather
/// than resurrecting a dead handle).
#[wasm_bindgen]
pub fn destroy_pipeline(handle: u32) -> Result<(), JsValue> {
    with_gpu(|gpu| {
        gpu.pipelines.remove(&handle);
        gpu.pipeline_cache.retain(|_, v| *v != handle);
        Ok(())
    })
}

/// Dispatches `pipeline_handle` over `resource_handles` (bound in order --
/// `resource_handles[i]` goes to `@binding(i)`, and must be the kind of
/// resource (buffer/texture/sampler) that pipeline's layout was built with
/// at that index) with `(wg_x, wg_y, wg_z)` workgroups. Synchronous
/// (`queue.submit` doesn't wait for completion) and cheap enough to call
/// every animation frame -- the expensive parts (shader compile, pipeline/
/// layout creation) already happened in `create_pipeline`; this only
/// builds a fresh bind group (bind groups are cheap, and the resource
/// handles may differ call to call) and submits one compute pass.
#[wasm_bindgen]
pub fn dispatch(pipeline_handle: u32, resource_handles: Vec<u32>, wg_x: u32, wg_y: u32, wg_z: u32) -> Result<(), JsValue> {
    with_gpu(|gpu| {
        let pipeline_entry = gpu
            .pipelines
            .get(&pipeline_handle)
            .ok_or_else(|| JsValue::from_str(&format!("dispatch: unknown pipeline handle {pipeline_handle}")))?;
        if resource_handles.len() != pipeline_entry.binding_kinds.len() {
            return Err(JsValue::from_str(&format!(
                "dispatch: pipeline expects {} bound resources, got {}",
                pipeline_entry.binding_kinds.len(),
                resource_handles.len()
            )));
        }
        let mut entries = Vec::with_capacity(resource_handles.len());
        for (i, h) in resource_handles.iter().enumerate() {
            let resource = resolve_binding_resource(gpu, *h)?;
            entries.push(wgpu::BindGroupEntry { binding: i as u32, resource });
        }
        let bind_group = gpu.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("tsubaki-gpu dispatch bind group"),
            layout: &pipeline_entry.bind_group_layout,
            entries: &entries,
        });
        let mut encoder = gpu.device.create_command_encoder(&wgpu::CommandEncoderDescriptor {
            label: Some("tsubaki-gpu dispatch encoder"),
        });
        {
            let mut pass = encoder.begin_compute_pass(&wgpu::ComputePassDescriptor {
                label: Some("tsubaki-gpu dispatch pass"),
                timestamp_writes: None,
            });
            pass.set_pipeline(&pipeline_entry.pipeline);
            pass.set_bind_group(0, &bind_group, &[]);
            pass.dispatch_workgroups(wg_x, wg_y, wg_z);
        }
        gpu.queue.submit(Some(encoder.finish()));
        Ok(())
    })
}

/// Targets `canvas` for rendering -- creates a `wgpu::Surface` from it and
/// configures it at `(width, height)` using whatever format/present mode
/// the adapter actually prefers for that surface (queried via
/// `get_capabilities`, not assumed). Call once before `create_render_pipeline`/
/// `render`; the WGSL rendered TO this canvas is, same as everywhere else in
/// this crate, supplied by the caller -- nothing render-shaped is hardcoded
/// in Rust here, only the plumbing to compile and run it.
///
/// `alpha_mode` is `"opaque"` (the canvas is always fully opaque, whatever
/// alpha you render is ignored -- the old, only, behavior before this
/// parameter existed) or `"premultiplied"` (the canvas genuinely
/// composites with the page behind it, e.g. CSS `background` showing
/// through wherever you clear/draw with alpha < 1). The real WebGPU spec
/// only defines these two `GPUCanvasAlphaMode` values for canvas contexts
/// -- native-only variants like `PostMultiplied` exist on `wgpu::
/// CompositeAlphaMode` but the browser will never report supporting them,
/// so asking for anything else is a real, checked error here (against
/// `get_capabilities`), not a silent fallback to whatever the browser
/// felt like giving you.
///
/// Choosing `"premultiplied"` is only half the job: WebGPU requires the
/// texture's OWN color values to already be premultiplied by their alpha
/// (`rgb * a`, not straight `rgb`) for this mode to composite correctly --
/// that's a caller-side responsibility (premultiply your colors before
/// writing them into whatever buffer/texture feeds your shader, and use
/// `"premultiplied-alpha"` blend in `create_render_pipeline`, not
/// `"alpha"`), not something this function can do on your behalf.
#[wasm_bindgen]
pub fn configure_canvas(
    canvas: web_sys::HtmlCanvasElement,
    width: u32,
    height: u32,
    alpha_mode: String,
) -> Result<(), JsValue> {
    let requested_alpha_mode = match alpha_mode.as_str() {
        "opaque" => wgpu::CompositeAlphaMode::Opaque,
        "premultiplied" => wgpu::CompositeAlphaMode::PreMultiplied,
        other => {
            return Err(JsValue::from_str(&format!(
                "configure_canvas: unknown alpha_mode {other:?} -- expected \"opaque\" or \"premultiplied\""
            )))
        }
    };
    with_gpu(|gpu| {
        // Reuses the SAME `Instance` `gpu_init` built (and ran webgpu
        // detection against) -- a fresh `Instance::default()` here could
        // re-enable backends detection deliberately turned off, producing
        // a surface that doesn't match `gpu.adapter`/`gpu.device`'s actual
        // backend.
        let surface = gpu
            .instance
            .create_surface(wgpu::SurfaceTarget::Canvas(canvas))
            .map_err(|e| JsValue::from_str(&format!("create_surface failed: {e}")))?;
        let caps = surface.get_capabilities(&gpu.adapter);
        let format = *caps
            .formats
            .first()
            .ok_or_else(|| JsValue::from_str("configure_canvas: adapter reports no supported surface format"))?;
        // wgpu 30.0.0 の webgpu バックエンドは web canvas の alpha_modes を
        // [Opaque] としか報告しないが、WebGPU 仕様の canvas は premultiplied も
        // 標準で持つ。capabilities を鵜呑みにせず、premultiplied は configure を
        // 試みる（opaque と未知値は従来どおり弾く）。
        let known = requested_alpha_mode == wgpu::CompositeAlphaMode::PreMultiplied
            || caps.alpha_modes.contains(&requested_alpha_mode);
        if !known {
            return Err(JsValue::from_str(&format!(
                "configure_canvas: this canvas doesn't support alpha_mode {alpha_mode:?} -- it supports {:?}",
                caps.alpha_modes
            )));
        }
        let config = wgpu::SurfaceConfiguration {
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
            format,
            color_space: wgpu::SurfaceColorSpace::Auto,
            width,
            height,
            present_mode: caps.present_modes.first().copied().unwrap_or(wgpu::PresentMode::Fifo),
            alpha_mode: requested_alpha_mode,
            view_formats: vec![],
            desired_maximum_frame_latency: 2,
        };
        surface.configure(&gpu.device, &config);

        let msaa_texture = gpu.device.create_texture(&wgpu::TextureDescriptor {
            label: Some("tsubaki-gpu msaa target"),
            size: wgpu::Extent3d { width, height, depth_or_array_layers: 1 },
            mip_level_count: 1,
            sample_count: MSAA_SAMPLES,
            dimension: wgpu::TextureDimension::D2,
            format,
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
            view_formats: &[],
        });
        let msaa_view = msaa_texture.create_view(&wgpu::TextureViewDescriptor::default());

        gpu.surface = Some(surface);
        gpu.surface_format = Some(format);
        gpu.msaa_target = Some(MsaaTarget { texture: msaa_texture, view: msaa_view });
        Ok(())
    })
}

/// Compiles `wgsl` (must define a `@vertex fn <vertex_entry>(...)` and a
/// `@fragment fn <fragment_entry>(...)`, same module) into a render
/// pipeline targeting whatever `configure_canvas` configured -- call that
/// first. No vertex-buffer layout at all: a triangle (or anything else)
/// generated purely from `@builtin(vertex_index)` inside the WGSL itself
/// (the classic "hello triangle" shape) needs none, and this crate isn't
/// trying to build a general vertex-buffer/attribute system nobody asked
/// for yet. `binding_kinds` works exactly like `create_pipeline`'s (empty
/// is fine -- a plain hardcoded-vertex triangle needs no bindings at all),
/// except bindings here are visible to BOTH vertex and fragment stages.
/// `topology` is `"triangle-list"` (default-shaped), `"triangle-strip"`,
/// `"line-list"`, `"line-strip"`, or `"point-list"` -- lines/points need
/// this to draw as anything but triangles. `blend` is `"replace"` (opaque,
/// each draw fully overwrites what was there), `"alpha"`, or
/// `"premultiplied-alpha"` -- needed for compositing multiple draws in one
/// frame (e.g. text over a diagram) via `draw_frame`, see its doc comment.
/// Same content-hash cache, same `get_compilation_info`-based error
/// reporting (and the same disclosed gap: only shader-source errors are
/// caught, not later-stage ones) as `create_pipeline` -- see its doc
/// comment for why error scopes aren't used here either.
#[wasm_bindgen]
pub async fn create_render_pipeline(
    wgsl: String,
    vertex_entry: String,
    fragment_entry: String,
    binding_kinds: Vec<String>,
    topology: String,
    blend: String,
) -> Result<u32, JsValue> {
    let binding_kinds: Vec<BindingKind> =
        binding_kinds.iter().map(|s| BindingKind::parse(s)).collect::<Result<_, _>>()?;
    let topology = parse_topology(&topology)?;
    let blend = parse_blend(&blend)?;
    let key = content_hash(
        &[&wgsl, &vertex_entry, &fragment_entry, &format!("{topology:?}"), &format!("{blend:?}")],
        &binding_kinds,
    );
    if let Some(handle) = with_gpu(|gpu| Ok(gpu.render_pipeline_cache.get(&key).copied()))? {
        return Ok(handle);
    }

    let (device, format) = with_gpu(|gpu| {
        let format = gpu
            .surface_format
            .ok_or_else(|| JsValue::from_str("configure_canvas() must be called before create_render_pipeline()"))?;
        Ok((gpu.device.clone(), format))
    })?;

    let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
        label: Some("tsubaki-gpu render shader"),
        source: wgpu::ShaderSource::Wgsl(wgsl.into()),
    });

    let compilation_errors: Vec<String> = shader
        .get_compilation_info()
        .await
        .messages
        .into_iter()
        .filter(|m| m.message_type == wgpu::CompilationMessageType::Error)
        .map(|m| m.message)
        .collect();
    if !compilation_errors.is_empty() {
        return Err(JsValue::from_str(&format!(
            "create_render_pipeline: WGSL error(s): {}",
            compilation_errors.join("; ")
        )));
    }

    let layout_entries: Vec<_> = binding_kinds
        .iter()
        .enumerate()
        .map(|(i, k)| k.layout_entry(i as u32, wgpu::ShaderStages::VERTEX_FRAGMENT))
        .collect();
    let bind_group_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
        label: Some("tsubaki-gpu render bind group layout"),
        entries: &layout_entries,
    });
    let pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
        label: Some("tsubaki-gpu render pipeline layout"),
        bind_group_layouts: &[Some(&bind_group_layout)],
        immediate_size: 0,
    });
    let pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
        label: Some("tsubaki-gpu render pipeline"),
        layout: Some(&pipeline_layout),
        vertex: wgpu::VertexState {
            module: &shader,
            entry_point: Some(&vertex_entry),
            compilation_options: Default::default(),
            buffers: &[],
        },
        fragment: Some(wgpu::FragmentState {
            module: &shader,
            entry_point: Some(&fragment_entry),
            compilation_options: Default::default(),
            targets: &[Some(wgpu::ColorTargetState {
                format,
                blend: Some(blend),
                write_mask: wgpu::ColorWrites::ALL,
            })],
        }),
        primitive: wgpu::PrimitiveState { topology, ..Default::default() },
        depth_stencil: None,
        multisample: wgpu::MultisampleState { count: MSAA_SAMPLES, mask: !0, alpha_to_coverage_enabled: false },
        multiview_mask: None,
        cache: None,
    });

    with_gpu(|gpu| {
        let handle = gpu.alloc_handle();
        gpu.render_pipelines.insert(handle, RenderPipelineEntry { pipeline, bind_group_layout, binding_kinds });
        gpu.render_pipeline_cache.insert(key, handle);
        Ok(handle)
    })
}

/// Destroys a render pipeline (and drops it from its content-hash cache).
#[wasm_bindgen]
pub fn destroy_render_pipeline(handle: u32) -> Result<(), JsValue> {
    with_gpu(|gpu| {
        gpu.render_pipelines.remove(&handle);
        gpu.render_pipeline_cache.retain(|_, v| *v != handle);
        Ok(())
    })
}

/// Opens a new frame: grabs the canvas' current surface texture and clears
/// it to `(clear_r, clear_g, clear_b, clear_a)`. Follow with any number of
/// `draw_frame` calls, then `end_frame` to present. Split into three calls
/// (rather than one do-everything `render`) specifically so a scene with
/// several draws (a curve, then points, then text labels) composes onto
/// ONE frame -- each `draw_frame` loads what's already there instead of
/// re-clearing, so later draws layer on top of earlier ones (with `"alpha"`
/// blend on the pipelines that need to, see `create_render_pipeline`)
/// instead of each one wiping the canvas back to the clear color.
#[wasm_bindgen]
pub fn begin_frame(clear_r: f64, clear_g: f64, clear_b: f64, clear_a: f64) -> Result<(), JsValue> {
    with_gpu(|gpu| {
        if gpu.current_frame.is_some() {
            return Err(JsValue::from_str("begin_frame: a frame is already open -- call end_frame first"));
        }
        let surface = gpu
            .surface
            .as_ref()
            .ok_or_else(|| JsValue::from_str("configure_canvas() must be called before begin_frame()"))?;
        // `get_current_texture` returns an enum, not a `Result` -- `Success`/
        // `Suboptimal` both carry a real `SurfaceTexture` to render into
        // (Suboptimal just means the canvas should ideally be reconfigured
        // soon, e.g. after a resize; still fine to render this frame); the
        // rest are real misses with nothing to draw into.
        let surface_texture = match surface.get_current_texture() {
            wgpu::CurrentSurfaceTexture::Success(t) | wgpu::CurrentSurfaceTexture::Suboptimal(t) => t,
            other => {
                return Err(JsValue::from_str(&format!(
                    "begin_frame: no current surface texture available ({other:?})"
                )))
            }
        };
        let surface_view = surface_texture.texture.create_view(&wgpu::TextureViewDescriptor::default());
        let mut encoder = gpu
            .device
            .create_command_encoder(&wgpu::CommandEncoderDescriptor { label: Some("tsubaki-gpu frame encoder") });
        {
            let msaa_view = &gpu
                .msaa_target
                .as_ref()
                .ok_or_else(|| JsValue::from_str("configure_canvas() must be called before begin_frame()"))?
                .view;
            // A draw-less pass whose only job is the clear -- every
            // `draw_frame` pass after this one uses `LoadOp::Load`
            // unconditionally, so this is the one and only place the clear
            // color is applied. Draws into the persistent MSAA target and
            // resolves into the surface immediately -- so even a frame
            // with zero draw_frame calls still presents a (cleared, resolved)
            // surface instead of a stale one.
            let _pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("tsubaki-gpu begin_frame clear pass"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: msaa_view,
                    depth_slice: None,
                    resolve_target: Some(&surface_view),
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(wgpu::Color { r: clear_r, g: clear_g, b: clear_b, a: clear_a }),
                        store: wgpu::StoreOp::Store,
                    },
                })],
                depth_stencil_attachment: None,
                timestamp_writes: None,
                occlusion_query_set: None,
                multiview_mask: None,
            });
        }
        gpu.current_frame = Some(FrameState { surface_texture, surface_view, encoder });
        Ok(())
    })
}

/// Draws `vertex_count` vertices, `instance_count` times (pass `1` for the
/// old single-instance behavior), with `pipeline_handle` and
/// `resource_handles` bound the same way `dispatch` binds them, onto the
/// frame `begin_frame` opened. Synchronous; cheap enough to call several
/// times per frame (a curve, then a handful of points, then a few text
/// labels -- exactly the shape a diagram-with-labels toy needs).
///
/// Per-instance data (e.g. one entity's world position) is the WGSL
/// shader's own job to read, via `@builtin(instance_index)` indexing into a
/// bound storage buffer -- there's no separate per-instance vertex-buffer
/// mechanism here, same "caller always supplies the shader text, this crate
/// just binds resources" posture `dispatch`'s workgroup counts already use
/// for compute. A thousand entities' positions, already flattened by
/// Tsubaki's own `soa_flatten` (bin/ecs.ml) straight from ECS's SoA columns,
/// is exactly that kind of buffer.
#[wasm_bindgen]
pub fn draw_frame(pipeline_handle: u32, resource_handles: Vec<u32>, vertex_count: u32, instance_count: u32) -> Result<(), JsValue> {
    with_gpu(|gpu| {
        let pipeline_entry = gpu
            .render_pipelines
            .get(&pipeline_handle)
            .ok_or_else(|| JsValue::from_str(&format!("draw_frame: unknown render pipeline handle {pipeline_handle}")))?;
        if resource_handles.len() != pipeline_entry.binding_kinds.len() {
            return Err(JsValue::from_str(&format!(
                "draw_frame: pipeline expects {} bound resources, got {}",
                pipeline_entry.binding_kinds.len(),
                resource_handles.len()
            )));
        }
        let mut entries = Vec::with_capacity(resource_handles.len());
        for (i, h) in resource_handles.iter().enumerate() {
            let resource = resolve_binding_resource(gpu, *h)?;
            entries.push(wgpu::BindGroupEntry { binding: i as u32, resource });
        }
        let bind_group = gpu.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("tsubaki-gpu draw_frame bind group"),
            layout: &pipeline_entry.bind_group_layout,
            entries: &entries,
        });

        let msaa_view = &gpu
            .msaa_target
            .as_ref()
            .ok_or_else(|| JsValue::from_str("draw_frame: no MSAA target -- call configure_canvas first"))?
            .view;
        let frame = gpu
            .current_frame
            .as_mut()
            .ok_or_else(|| JsValue::from_str("draw_frame: no open frame -- call begin_frame first"))?;
        {
            let mut pass = frame.encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("tsubaki-gpu draw_frame pass"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: msaa_view,
                    depth_slice: None,
                    resolve_target: Some(&frame.surface_view),
                    ops: wgpu::Operations { load: wgpu::LoadOp::Load, store: wgpu::StoreOp::Store },
                })],
                depth_stencil_attachment: None,
                timestamp_writes: None,
                occlusion_query_set: None,
                multiview_mask: None,
            });
            pass.set_pipeline(&pipeline_entry.pipeline);
            pass.set_bind_group(0, &bind_group, &[]);
            pass.draw(0..vertex_count, 0..instance_count);
        }
        Ok(())
    })
}

/// Submits every `draw_frame` call since `begin_frame` and presents.
#[wasm_bindgen]
pub fn end_frame() -> Result<(), JsValue> {
    with_gpu(|gpu| {
        let frame = gpu
            .current_frame
            .take()
            .ok_or_else(|| JsValue::from_str("end_frame: no open frame -- call begin_frame first"))?;
        gpu.queue.submit(Some(frame.encoder.finish()));
        gpu.queue.present(frame.surface_texture);
        Ok(())
    })
}

/// Drops the whole GPU context (device/queue/surface/every buffer &
/// pipeline) -- deterministic, since none of these form reference cycles,
/// not GC-timing-dependent. Call from a toy's teardown; `gpu_init` again to
/// start a fresh context afterward.
#[wasm_bindgen]
pub fn gpu_shutdown() {
    GPU.with(|cell| *cell.borrow_mut() = None);
}
