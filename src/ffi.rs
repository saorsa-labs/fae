//! C ABI surface for embedding the Fae runtime in native shells.
//!
//! Provides an opaque `FaeRuntime` handle behind 8 `extern "C"` functions that
//! Swift (or any C-compatible language) can call directly from a statically
//! linked `libfae.a`.
//!
//! # Lifecycle
//!
//! ```text
//! fae_core_init(config_json) → handle
//! fae_core_start(handle) → 0 on success
//! fae_core_send_command(handle, json) → response json  (caller frees via fae_string_free)
//! fae_core_poll_event(handle) → event json | null       (caller frees via fae_string_free)
//! fae_core_set_event_callback(handle, cb, user_data)
//! fae_core_stop(handle)
//! fae_core_destroy(handle)
//! ```
//!
//! # Thread safety
//!
//! All functions are safe to call from any thread. Interior mutability is
//! protected by `Mutex`.

use std::ffi::{CStr, CString, c_char, c_void};
use std::sync::Mutex;

use crate::host::channel::{HostCommandServer, NoopDeviceTransferHandler, command_channel};
use crate::host::contract::{CommandEnvelope, EventEnvelope};
use tokio::sync::broadcast;

// ── Types ──────────────────────────────────────────────────────────────────

/// Callback signature for event notifications from the Fae runtime.
///
/// # Safety
///
/// The `event_json` pointer is valid only for the duration of the callback
/// invocation. The caller (Fae) owns the string and will free it after the
/// callback returns. `user_data` is the pointer passed to
/// `fae_core_set_event_callback`.
pub type FaeEventCallback = unsafe extern "C" fn(event_json: *const c_char, user_data: *mut c_void);

/// Configuration parsed from the JSON string passed to `fae_core_init`.
#[derive(Debug, Default, serde::Deserialize)]
#[serde(default)]
struct FaeInitConfig {
    /// Log level filter (default: "info"). Reserved for Phase 1.3 tracing
    /// integration; parsed from JSON but not yet wired to a subscriber.
    _log_level: Option<String>,
    /// Broadcast channel capacity for events (default: 64).
    event_buffer_size: Option<usize>,
}

// ── Runtime handle ─────────────────────────────────────────────────────────

/// Internal state behind the opaque `*mut c_void` handle.
struct FaeRuntime {
    tokio_rt: tokio::runtime::Runtime,
    client: crate::host::channel::HostCommandClient,
    event_rx: Mutex<broadcast::Receiver<EventEnvelope>>,
    callback: Mutex<Option<FaeEventCallback>>,
    callback_user_data: Mutex<*mut c_void>,
    started: Mutex<bool>,
    server: Mutex<Option<HostCommandServer<NoopDeviceTransferHandler>>>,
    server_handle: Mutex<Option<tokio::task::JoinHandle<()>>>,
}

// SAFETY: All mutable interior state is behind `Mutex`. The raw
// `callback_user_data` pointer is caller-managed and must remain valid for
// the lifetime of the callback registration.
unsafe impl Send for FaeRuntime {}
unsafe impl Sync for FaeRuntime {}

impl FaeRuntime {
    /// Drain the event broadcast channel and invoke the callback (if set)
    /// for each event. Called synchronously after `send_command` so the
    /// Swift layer sees events immediately.
    fn drain_events(&self) {
        let cb = {
            let guard = match self.callback.lock() {
                Ok(g) => g,
                Err(_) => return,
            };
            *guard
        };
        let user_data = {
            let guard = match self.callback_user_data.lock() {
                Ok(g) => g,
                Err(_) => return,
            };
            *guard
        };

        let mut rx = match self.event_rx.lock() {
            Ok(g) => g,
            Err(_) => return,
        };

        while let Ok(event) = rx.try_recv() {
            if let Some(cb) = cb
                && let Ok(json) = serde_json::to_string(&event)
                && let Ok(cstr) = CString::new(json)
            {
                // SAFETY: callback and user_data were provided by the
                // caller via fae_core_set_event_callback and must
                // remain valid. The CString pointer is valid for this
                // scope.
                unsafe {
                    cb(cstr.as_ptr(), user_data);
                }
            }
        }
    }
}

// ── Helpers ────────────────────────────────────────────────────────────────

/// Convert a nullable C string pointer to a `&str`.
///
/// Returns `None` if `ptr` is null or if the bytes are not valid UTF-8.
///
/// # Safety
///
/// `ptr` must be null or point to a valid null-terminated C string.
unsafe fn cstr_to_str<'a>(ptr: *const c_char) -> Option<&'a str> {
    if ptr.is_null() {
        return None;
    }
    // SAFETY: caller guarantees ptr is null or a valid C string.
    unsafe { CStr::from_ptr(ptr) }.to_str().ok()
}

/// Convert a Rust `String` to a C-owned `*mut c_char`.
///
/// The caller must free the returned pointer via `fae_string_free`.
/// Returns null if the string contains an interior NUL byte.
fn string_to_c(s: String) -> *mut c_char {
    match CString::new(s) {
        Ok(cs) => cs.into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Recover a `&FaeRuntime` from an opaque handle.
///
/// # Safety
///
/// `handle` must be a non-null pointer returned by `fae_core_init` that has
/// not yet been passed to `fae_core_destroy`.
unsafe fn borrow_runtime<'a>(handle: *mut c_void) -> Option<&'a FaeRuntime> {
    if handle.is_null() {
        return None;
    }
    // SAFETY: handle was created by Box::into_raw in fae_core_init.
    Some(unsafe { &*(handle as *const FaeRuntime) })
}

// ── Extern "C" functions ──────────────────────────────────────────────────

/// Create a new Fae runtime from a JSON configuration string.
///
/// Returns an opaque handle on success, or null on failure (e.g. null input,
/// invalid JSON, or runtime creation failure).
///
/// # Safety
///
/// `config_json` must be null or a valid null-terminated C string containing
/// JSON. The returned handle must eventually be passed to `fae_core_destroy`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn fae_core_init(config_json: *const c_char) -> *mut c_void {
    // SAFETY: caller guarantees config_json is null or a valid C string.
    let json_str = match unsafe { cstr_to_str(config_json) } {
        Some(s) => s,
        None => return std::ptr::null_mut(),
    };

    let config: FaeInitConfig = match serde_json::from_str(json_str) {
        Ok(c) => c,
        Err(_) => return std::ptr::null_mut(),
    };

    let tokio_rt = match tokio::runtime::Runtime::new() {
        Ok(rt) => rt,
        Err(_) => return std::ptr::null_mut(),
    };

    let event_capacity = config.event_buffer_size.unwrap_or(64).max(1);
    let handler = NoopDeviceTransferHandler;
    let (client, server) = command_channel(32, event_capacity, handler);
    let event_rx = client.subscribe_events();

    let runtime = Box::new(FaeRuntime {
        tokio_rt,
        client,
        event_rx: Mutex::new(event_rx),
        callback: Mutex::new(None),
        callback_user_data: Mutex::new(std::ptr::null_mut()),
        started: Mutex::new(false),
        server: Mutex::new(Some(server)),
        server_handle: Mutex::new(None),
    });

    Box::into_raw(runtime) as *mut c_void
}

/// Start the Fae runtime (spawns the command server on the tokio runtime).
///
/// Returns 0 on success, -1 on failure (null handle, already started, or
/// server already consumed).
///
/// # Safety
///
/// `handle` must be a valid handle from `fae_core_init`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn fae_core_start(handle: *mut c_void) -> i32 {
    // SAFETY: handle is from fae_core_init and not yet destroyed.
    let rt = match unsafe { borrow_runtime(handle) } {
        Some(r) => r,
        None => return -1,
    };

    let mut started = match rt.started.lock() {
        Ok(g) => g,
        Err(_) => return -1,
    };
    if *started {
        return -1;
    }

    let server = {
        let mut guard = match rt.server.lock() {
            Ok(g) => g,
            Err(_) => return -1,
        };
        match guard.take() {
            Some(s) => s,
            None => return -1,
        }
    };

    let join_handle = rt.tokio_rt.spawn(server.run());

    if let Ok(mut guard) = rt.server_handle.lock() {
        *guard = Some(join_handle);
    }

    *started = true;
    0
}

/// Send a JSON command to the Fae runtime and return the JSON response.
///
/// The returned `*mut c_char` is owned by the caller and **must** be freed
/// via `fae_string_free`. Returns null on error (null handle, parse failure,
/// runtime not started).
///
/// If an event callback is registered, any events produced by the command
/// will be delivered synchronously before this function returns.
///
/// # Safety
///
/// `handle` must be a valid handle from `fae_core_init`. `command_json` must
/// be a valid null-terminated C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn fae_core_send_command(
    handle: *mut c_void,
    command_json: *const c_char,
) -> *mut c_char {
    // SAFETY: handle is from fae_core_init; command_json is a valid C string.
    let rt = match unsafe { borrow_runtime(handle) } {
        Some(r) => r,
        None => return std::ptr::null_mut(),
    };

    // SAFETY: caller guarantees command_json is a valid C string.
    let json_str = match unsafe { cstr_to_str(command_json) } {
        Some(s) => s,
        None => return std::ptr::null_mut(),
    };

    let envelope: CommandEnvelope = match serde_json::from_str(json_str) {
        Ok(e) => e,
        Err(_) => return std::ptr::null_mut(),
    };

    let response = rt.tokio_rt.block_on(rt.client.send(envelope));

    // Drain events and fire callbacks before returning.
    // Give the server task a moment to process and emit events.
    rt.tokio_rt.block_on(tokio::task::yield_now());
    rt.drain_events();

    match response {
        Ok(resp) => match serde_json::to_string(&resp) {
            Ok(json) => string_to_c(json),
            Err(_) => std::ptr::null_mut(),
        },
        Err(e) => {
            let error_resp = serde_json::json!({
                "ok": false,
                "error": format!("{e}"),
            });
            match serde_json::to_string(&error_resp) {
                Ok(json) => string_to_c(json),
                Err(_) => std::ptr::null_mut(),
            }
        }
    }
}

/// Poll for the next pending event (non-blocking).
///
/// Returns a JSON string owned by the caller (free via `fae_string_free`),
/// or null if no events are pending.
///
/// # Safety
///
/// `handle` must be a valid handle from `fae_core_init`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn fae_core_poll_event(handle: *mut c_void) -> *mut c_char {
    // SAFETY: handle is from fae_core_init.
    let rt = match unsafe { borrow_runtime(handle) } {
        Some(r) => r,
        None => return std::ptr::null_mut(),
    };

    let mut rx = match rt.event_rx.lock() {
        Ok(g) => g,
        Err(_) => return std::ptr::null_mut(),
    };

    match rx.try_recv() {
        Ok(event) => match serde_json::to_string(&event) {
            Ok(json) => string_to_c(json),
            Err(_) => std::ptr::null_mut(),
        },
        Err(_) => std::ptr::null_mut(),
    }
}

/// Register a callback for event notifications.
///
/// The callback will be invoked synchronously during `fae_core_send_command`
/// for any events the command produces. Pass `None` (null function pointer)
/// to unregister.
///
/// # Re-entrancy warning
///
/// The callback is invoked **synchronously** from within
/// `fae_core_send_command`. Do **not** call any `fae_core_*` function from
/// inside the callback — this will deadlock.
///
/// # Safety
///
/// `handle` must be a valid handle. `user_data` must remain valid for as
/// long as the callback is registered. The callback must be safe to call
/// from any thread.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn fae_core_set_event_callback(
    handle: *mut c_void,
    callback: Option<FaeEventCallback>,
    user_data: *mut c_void,
) {
    // SAFETY: handle is from fae_core_init.
    let rt = match unsafe { borrow_runtime(handle) } {
        Some(r) => r,
        None => return,
    };

    if let Ok(mut guard) = rt.callback.lock() {
        *guard = callback;
    }
    if let Ok(mut guard) = rt.callback_user_data.lock() {
        *guard = user_data;
    }
}

/// Stop the Fae runtime (cancels the server task).
///
/// After calling `fae_core_stop`, the handle is still valid but commands
/// will fail. Call `fae_core_destroy` to free the handle.
///
/// # Safety
///
/// `handle` must be a valid handle from `fae_core_init`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn fae_core_stop(handle: *mut c_void) {
    // SAFETY: handle is from fae_core_init.
    let rt = match unsafe { borrow_runtime(handle) } {
        Some(r) => r,
        None => return,
    };

    if let Ok(mut guard) = rt.server_handle.lock()
        && let Some(jh) = guard.take()
    {
        jh.abort();
    }

    if let Ok(mut guard) = rt.started.lock() {
        *guard = false;
    }
}

/// Destroy the Fae runtime handle and free all associated resources.
///
/// After this call the handle is invalid and must not be used again.
///
/// # Safety
///
/// `handle` must be a valid handle from `fae_core_init` (or null, which is
/// a no-op). Must not be called more than once for the same handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn fae_core_destroy(handle: *mut c_void) {
    if handle.is_null() {
        return;
    }
    // SAFETY: handle was created by Box::into_raw in fae_core_init.
    // This reclaims ownership and drops all resources.
    let _ = unsafe { Box::from_raw(handle as *mut FaeRuntime) };
}

/// Free a string returned by `fae_core_send_command` or `fae_core_poll_event`.
///
/// Passing null is a safe no-op.
///
/// # Safety
///
/// `s` must be null or a pointer previously returned by one of the
/// `fae_core_*` functions. Must not be freed more than once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn fae_string_free(s: *mut c_char) {
    if s.is_null() {
        return;
    }
    // SAFETY: s was created by CString::into_raw in string_to_c.
    let _ = unsafe { CString::from_raw(s) };
}
