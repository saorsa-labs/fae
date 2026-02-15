//! Secure memory-clearing utilities.
//!
//! Provides best-effort zeroing of sensitive data in memory using volatile
//! writes to prevent the compiler from optimising the clear away.

/// Overwrite a `String`'s backing buffer with zeros, then truncate it.
///
/// Uses [`std::ptr::write_volatile`] so the compiler cannot elide the writes.
///
/// # Safety note
///
/// This is **best-effort**. Prior `String` reallocations (e.g. from `push_str`
/// or `clone`) may leave copies of the secret in freed heap memory that we
/// cannot reach. OS page-out may also copy the data to swap. For maximum
/// protection, consider pinning pages with `mlock` (platform-specific).
pub fn secure_clear(s: &mut String) {
    // SAFETY: `as_mut_vec()` is unsafe because writing arbitrary bytes can
    // violate UTF-8 invariants. We only write zeros (valid UTF-8 single-byte
    // codepoint U+0000) and immediately call `clear()` to set the length to 0.
    let bytes = unsafe { s.as_mut_vec() };
    for byte in bytes.iter_mut() {
        // SAFETY: The pointer is derived from a mutable reference to an
        // element within the Vec's allocation, so it is valid, aligned, and
        // dereferenceable.
        unsafe {
            std::ptr::write_volatile(byte, 0);
        }
    }
    s.clear();
}

/// Clear an `Option<String>`, zeroing the inner value if present.
///
/// After calling, the option will be `None`.
pub fn secure_clear_option(opt: &mut Option<String>) {
    if let Some(s) = opt {
        secure_clear(s);
    }
    *opt = None;
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use super::*;

    #[test]
    fn secure_clear_zeros_memory() {
        let mut s = String::from("secret-api-key-12345");
        let ptr = s.as_ptr();
        let len = s.len();

        secure_clear(&mut s);

        assert!(s.is_empty());
        // Verify the backing buffer is zeroed (capacity preserved).
        assert!(s.capacity() >= len);
        for i in 0..len {
            // SAFETY: We still own the allocation (capacity >= len) and are
            // reading within the original bounds.
            let byte = unsafe { *ptr.add(i) };
            assert_eq!(byte, 0, "byte at offset {i} was not zeroed");
        }
    }

    #[test]
    fn secure_clear_empty_string() {
        let mut s = String::new();
        secure_clear(&mut s);
        assert!(s.is_empty());
    }

    #[test]
    fn secure_clear_long_string() {
        let mut s = "x".repeat(5000);
        let len = s.len();
        let ptr = s.as_ptr();

        secure_clear(&mut s);

        assert!(s.is_empty());
        for i in 0..len {
            let byte = unsafe { *ptr.add(i) };
            assert_eq!(byte, 0, "byte at offset {i} was not zeroed");
        }
    }

    #[test]
    fn secure_clear_option_some() {
        let mut opt = Some("secret".to_owned());
        secure_clear_option(&mut opt);
        assert!(opt.is_none());
    }

    #[test]
    fn secure_clear_option_none() {
        let mut opt: Option<String> = None;
        secure_clear_option(&mut opt);
        assert!(opt.is_none());
    }
}
