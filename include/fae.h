/**
 * @file fae.h
 * @brief C ABI surface for embedding the Fae runtime in native shells.
 *
 * This header declares the 8 extern "C" functions exported by libfae.a.
 * Swift can import this header via a bridging header or a C module map.
 *
 * ## Lifecycle
 *
 *     FaeCoreHandle h = fae_core_init("{}");
 *     fae_core_start(h);
 *     char *resp = fae_core_send_command(h, "{\"v\":1,...}");
 *     fae_string_free(resp);
 *     fae_core_stop(h);
 *     fae_core_destroy(h);
 *
 * ## Memory ownership
 *
 * | Function              | Allocates          | Who frees           |
 * |-----------------------|--------------------|---------------------|
 * | fae_core_init         | FaeCoreHandle      | fae_core_destroy    |
 * | fae_core_send_command | char* response     | fae_string_free     |
 * | fae_core_poll_event   | char* event (or 0) | fae_string_free     |
 * | fae_string_free       | -                  | (this IS the free)  |
 *
 * ## Thread safety
 *
 * All functions are safe to call from any thread.
 *
 * ## Re-entrancy warning
 *
 * The event callback registered via fae_core_set_event_callback is invoked
 * synchronously during fae_core_send_command. Do NOT call any fae_core_*
 * function from within the callback — this will deadlock.
 */

#ifndef FAE_H
#define FAE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/** Opaque handle to a Fae runtime instance. */
typedef void *FaeCoreHandle;

/**
 * Callback invoked when the runtime emits an event.
 *
 * @param event_json  Null-terminated JSON string (valid only during callback).
 * @param user_data   The pointer passed to fae_core_set_event_callback.
 */
typedef void (*FaeEventCallback)(const char *event_json, void *user_data);

/**
 * Create a new Fae runtime from a JSON configuration string.
 *
 * @param config_json  Null-terminated JSON string (e.g. "{}"). NULL returns NULL.
 * @return Opaque handle on success, NULL on failure.
 */
FaeCoreHandle fae_core_init(const char *config_json);

/**
 * Start the Fae runtime (spawns the command server).
 *
 * @param handle  Handle from fae_core_init.
 * @return 0 on success, -1 on failure.
 */
int32_t fae_core_start(FaeCoreHandle handle);

/**
 * Send a JSON command and receive a JSON response.
 *
 * The returned string is owned by the caller and MUST be freed via
 * fae_string_free. Returns NULL on error.
 *
 * If an event callback is registered, events are delivered synchronously
 * before this function returns.
 *
 * @param handle        Handle from fae_core_init.
 * @param command_json  Null-terminated JSON command envelope.
 * @return Owned JSON response string, or NULL.
 */
char *fae_core_send_command(FaeCoreHandle handle, const char *command_json);

/**
 * Poll for the next pending event (non-blocking).
 *
 * @param handle  Handle from fae_core_init.
 * @return Owned JSON event string, or NULL if no events are pending.
 */
char *fae_core_poll_event(FaeCoreHandle handle);

/**
 * Register a callback for event notifications.
 *
 * Pass NULL callback to unregister.
 *
 * @param handle     Handle from fae_core_init.
 * @param callback   Function to call on events, or NULL to unregister.
 * @param user_data  Passed through to callback; must remain valid while registered.
 */
void fae_core_set_event_callback(FaeCoreHandle handle,
                                 FaeEventCallback callback,
                                 void *user_data);

/**
 * Stop the runtime (cancels the command server).
 *
 * The handle remains valid after stop — call fae_core_destroy to free it.
 *
 * @param handle  Handle from fae_core_init.
 */
void fae_core_stop(FaeCoreHandle handle);

/**
 * Destroy the runtime handle and free all resources.
 *
 * After this call the handle is invalid. Passing NULL is a no-op.
 *
 * @param handle  Handle from fae_core_init, or NULL.
 */
void fae_core_destroy(FaeCoreHandle handle);

/**
 * Free a string returned by fae_core_send_command or fae_core_poll_event.
 *
 * Passing NULL is a safe no-op.
 *
 * @param s  String to free, or NULL.
 */
void fae_string_free(char *s);

/**
 * Linker dead-strip anchor — prevents the macOS linker from removing Rust
 * subsystems (ML models, audio, VAD, AEC) that are not directly reachable
 * from the 8 FFI entry points.
 *
 * Called internally by fae_core_init via black_box; no need to call directly.
 */
void fae_keep_alive(void);

#ifdef __cplusplus
}
#endif

#endif /* FAE_H */
