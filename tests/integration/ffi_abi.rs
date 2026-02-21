//! ABI-level FFI tests — call through the `extern "C"` function signatures.
//!
//! These tests call the FFI functions via `fae::ffi::*`, which are declared as
//! `pub unsafe extern "C" fn`.  Because the functions use the C calling
//! convention, this exercises the same ABI that a C/Swift caller would use.
//!
//! True linker-level symbol resolution is verified separately by building
//! `libfae.a` and checking with `nm`.

use std::ffi::{CStr, CString, c_char, c_void};
use std::ptr;
use std::sync::{Arc, Mutex};

use fae::ffi::{
    fae_core_destroy, fae_core_init, fae_core_poll_event, fae_core_send_command,
    fae_core_set_event_callback, fae_core_start, fae_core_stop, fae_string_free,
};

/// Calling `fae_core_init` with a null pointer returns null.
#[test]
fn ffi_abi_null_init_returns_null() {
    // SAFETY: passing null to fae_core_init is documented as returning null.
    let handle = unsafe { fae_core_init(ptr::null()) };
    assert!(handle.is_null(), "init(null) must return null");
}

/// Full lifecycle through the extern "C" ABI: init -> start -> stop -> destroy.
#[test]
fn ffi_abi_valid_init_start_stop_destroy() {
    let config = CString::new("{}").unwrap();

    // SAFETY: config is a valid null-terminated C string; handle is managed
    // through the full init -> start -> stop -> destroy sequence.
    unsafe {
        let handle = fae_core_init(config.as_ptr());
        assert!(!handle.is_null(), "init must return non-null handle");

        let start_rc = fae_core_start(handle);
        assert_eq!(start_rc, 0, "start must return 0 on success");

        fae_core_stop(handle);
        fae_core_destroy(handle);
    }
}

/// `host.ping` command round-trip through extern "C" ABI.
#[test]
fn ffi_abi_ping_command_roundtrip() {
    let config = CString::new("{}").unwrap();
    let ping_cmd =
        CString::new(r#"{"v":1,"command":"host.ping","payload":{},"request_id":"abi-test-1"}"#)
            .unwrap();

    // SAFETY: all pointers are valid, null-terminated C strings or handles
    // obtained from fae_core_init.
    unsafe {
        let handle = fae_core_init(config.as_ptr());
        assert!(!handle.is_null());

        let rc = fae_core_start(handle);
        assert_eq!(rc, 0);

        let response_ptr = fae_core_send_command(handle, ping_cmd.as_ptr());
        assert!(!response_ptr.is_null(), "send_command must return non-null");

        let response_str = CStr::from_ptr(response_ptr).to_str().unwrap();
        let response: serde_json::Value = serde_json::from_str(response_str).unwrap();
        assert_eq!(response["ok"], true, "response.ok must be true");
        assert_eq!(
            response["payload"]["pong"], true,
            "response must contain pong"
        );

        fae_string_free(response_ptr);
        fae_core_stop(handle);
        fae_core_destroy(handle);
    }
}

/// `fae_core_poll_event` returns null when no events are pending.
#[test]
fn ffi_abi_poll_event_returns_null_when_empty() {
    let config = CString::new("{}").unwrap();

    // SAFETY: handle obtained from fae_core_init, polled before any events.
    unsafe {
        let handle = fae_core_init(config.as_ptr());
        assert!(!handle.is_null());

        let rc = fae_core_start(handle);
        assert_eq!(rc, 0);

        let event_ptr = fae_core_poll_event(handle);
        assert!(
            event_ptr.is_null(),
            "poll_event must return null when no events pending"
        );

        fae_core_stop(handle);
        fae_core_destroy(handle);
    }
}

/// `fae_string_free(null)` is a safe no-op through extern "C" ABI.
#[test]
fn ffi_abi_string_free_null_is_noop() {
    // SAFETY: passing null to fae_string_free is documented as a no-op.
    unsafe {
        fae_string_free(ptr::null_mut());
    }
}

/// Event callback fires through extern "C" ABI when a command produces an event.
#[test]
fn ffi_abi_event_callback_fires() {
    let config = CString::new("{}").unwrap();
    let go_home_cmd = CString::new(
        r#"{"v":1,"command":"device.go_home","payload":{},"request_id":"abi-cb-test"}"#,
    )
    .unwrap();

    let received: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));

    unsafe extern "C" fn callback(event_json: *const c_char, user_data: *mut c_void) {
        if event_json.is_null() || user_data.is_null() {
            return;
        }
        // SAFETY: user_data points to an Arc<Mutex<Vec<String>>> that remains
        // valid for the duration of this test.
        unsafe {
            let collected = &*(user_data as *const Arc<Mutex<Vec<String>>>);
            if let Ok(s) = CStr::from_ptr(event_json).to_str()
                && let Ok(mut guard) = collected.lock()
            {
                guard.push(s.to_owned());
            }
        }
    }

    // SAFETY: all pointers are valid; user_data points to `received` which
    // outlives the callback registration.
    unsafe {
        let handle = fae_core_init(config.as_ptr());
        assert!(!handle.is_null());

        let rc = fae_core_start(handle);
        assert_eq!(rc, 0);

        let user_data = &received as *const Arc<Mutex<Vec<String>>> as *mut c_void;
        fae_core_set_event_callback(handle, Some(callback), user_data);

        let response_ptr = fae_core_send_command(handle, go_home_cmd.as_ptr());
        assert!(!response_ptr.is_null());
        fae_string_free(response_ptr);

        let events = received.lock().unwrap();
        assert!(
            !events.is_empty(),
            "callback must have been invoked at least once"
        );
        let event: serde_json::Value = serde_json::from_str(&events[0]).unwrap();
        assert_eq!(event["event"], "device.home_requested");

        fae_core_stop(handle);
        fae_core_destroy(handle);
    }
}
