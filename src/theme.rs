//! System theme detection and CSS variable generation.

use std::fmt;

/// System theme state (light or dark).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SystemTheme {
    /// Light appearance.
    Light,
    /// Dark appearance.
    Dark,
}

impl SystemTheme {
    /// Detect the current system theme.
    ///
    /// On macOS, this queries NSAppearance. On other platforms, defaults to Dark.
    pub fn current() -> Self {
        #[cfg(target_os = "macos")]
        {
            detect_macos_theme()
        }
        #[cfg(not(target_os = "macos"))]
        {
            Self::Dark
        }
    }

    /// Returns true if this is the dark theme.
    pub fn is_dark(self) -> bool {
        matches!(self, Self::Dark)
    }

    /// Returns true if this is the light theme.
    pub fn is_light(self) -> bool {
        matches!(self, Self::Light)
    }
}

impl fmt::Display for SystemTheme {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Light => write!(f, "light"),
            Self::Dark => write!(f, "dark"),
        }
    }
}

#[cfg(target_os = "macos")]
fn detect_macos_theme() -> SystemTheme {
    use objc2::msg_send;
    use objc2::rc::autoreleasepool;
    use objc2::runtime::AnyObject;
    use objc2_foundation::NSString;

    autoreleasepool(|_| {
        // Get the effective appearance name from NSApp
        let ns_app_class = objc2::class!(NSApplication);
        let ns_app: *mut AnyObject = unsafe { msg_send![ns_app_class, sharedApplication] };

        if ns_app.is_null() {
            // No NSApp available (shouldn't happen in GUI app, but be safe)
            return SystemTheme::Dark;
        }

        let effective_appearance: *mut AnyObject =
            unsafe { msg_send![ns_app, effectiveAppearance] };

        if effective_appearance.is_null() {
            return SystemTheme::Dark;
        }

        let name: *mut AnyObject = unsafe { msg_send![effective_appearance, name] };
        if name.is_null() {
            return SystemTheme::Dark;
        }

        // Convert NSString to Rust string
        let name_nsstring = unsafe { &*(name as *const NSString) };
        let name_str = name_nsstring.to_string();

        // Check if the name contains "Dark"
        if name_str.contains("Dark") {
            SystemTheme::Dark
        } else {
            SystemTheme::Light
        }
    })
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

    use super::*;

    #[test]
    fn system_theme_current_returns_valid() {
        let theme = SystemTheme::current();
        // Should be either Light or Dark
        assert!(theme == SystemTheme::Light || theme == SystemTheme::Dark);
    }

    #[test]
    fn system_theme_is_dark() {
        assert!(SystemTheme::Dark.is_dark());
        assert!(!SystemTheme::Light.is_dark());
    }

    #[test]
    fn system_theme_is_light() {
        assert!(SystemTheme::Light.is_light());
        assert!(!SystemTheme::Dark.is_light());
    }

    #[test]
    fn system_theme_display() {
        assert_eq!(SystemTheme::Light.to_string(), "light");
        assert_eq!(SystemTheme::Dark.to_string(), "dark");
    }

    #[test]
    fn non_macos_defaults_to_dark() {
        #[cfg(not(target_os = "macos"))]
        {
            assert_eq!(SystemTheme::current(), SystemTheme::Dark);
        }
    }

    #[test]
    #[cfg(target_os = "macos")]
    fn macos_theme_detection_does_not_panic() {
        // This test verifies the macOS detection code runs without panicking.
        // The actual theme value depends on system settings.
        let theme = SystemTheme::current();
        assert!(theme == SystemTheme::Light || theme == SystemTheme::Dark);
    }
}
