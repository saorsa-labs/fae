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

/// Generate CSS custom properties (variables) for the given theme.
///
/// Returns a CSS `:root { ... }` block with all theme-specific color variables.
pub fn generate_theme_css(theme: SystemTheme) -> String {
    match theme {
        SystemTheme::Light => LIGHT_THEME_CSS.to_string(),
        SystemTheme::Dark => DARK_THEME_CSS.to_string(),
    }
}

const DARK_THEME_CSS: &str = r#"
    :root {
        --bg-primary: #0f0f1a;
        --bg-secondary: #161625;
        --bg-card: rgba(255, 255, 255, 0.025);
        --bg-elevated: rgba(255, 255, 255, 0.04);
        --border-subtle: rgba(255, 255, 255, 0.07);
        --border-medium: rgba(255, 255, 255, 0.12);
        --accent: #a78bfa;
        --accent-dim: rgba(167, 139, 250, 0.15);
        --accent-glow: rgba(167, 139, 250, 0.25);
        --green: #22c55e;
        --green-dim: rgba(34, 197, 94, 0.12);
        --red: #ef4444;
        --red-dim: rgba(239, 68, 68, 0.12);
        --yellow: #fbbf24;
        --blue: #3b82f6;
        --text-primary: #f0eef6;
        --text-secondary: #a1a1b5;
        --text-tertiary: #6b6b80;
        --radius-sm: 8px;
        --radius-md: 12px;
        --radius-lg: 16px;
        --radius-pill: 999px;
    }
"#;

const LIGHT_THEME_CSS: &str = r#"
    :root {
        --bg-primary: #ffffff;
        --bg-secondary: #f8f9fa;
        --bg-card: rgba(0, 0, 0, 0.02);
        --bg-elevated: rgba(0, 0, 0, 0.04);
        --border-subtle: rgba(0, 0, 0, 0.08);
        --border-medium: rgba(0, 0, 0, 0.15);
        --accent: #7c3aed;
        --accent-dim: rgba(124, 58, 237, 0.10);
        --accent-glow: rgba(124, 58, 237, 0.20);
        --green: #16a34a;
        --green-dim: rgba(22, 163, 74, 0.10);
        --red: #dc2626;
        --red-dim: rgba(220, 38, 38, 0.10);
        --yellow: #ea580c;
        --blue: #2563eb;
        --text-primary: #0a0a0f;
        --text-secondary: #52525e;
        --text-tertiary: #a1a1aa;
        --radius-sm: 8px;
        --radius-md: 12px;
        --radius-lg: 16px;
        --radius-pill: 999px;
    }
"#;

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

    #[test]
    fn generate_theme_css_light_includes_required_variables() {
        let css = generate_theme_css(SystemTheme::Light);
        assert!(css.contains(":root"));
        assert!(css.contains("--bg-primary"));
        assert!(css.contains("--bg-secondary"));
        assert!(css.contains("--text-primary"));
        assert!(css.contains("--text-secondary"));
        assert!(css.contains("--accent"));
        assert!(css.contains("--green"));
        assert!(css.contains("--red"));
        assert!(css.contains("--radius-sm"));
    }

    #[test]
    fn generate_theme_css_dark_includes_required_variables() {
        let css = generate_theme_css(SystemTheme::Dark);
        assert!(css.contains(":root"));
        assert!(css.contains("--bg-primary"));
        assert!(css.contains("--bg-secondary"));
        assert!(css.contains("--text-primary"));
        assert!(css.contains("--text-secondary"));
        assert!(css.contains("--accent"));
        assert!(css.contains("--green"));
        assert!(css.contains("--red"));
        assert!(css.contains("--radius-sm"));
    }

    #[test]
    fn generate_theme_css_light_has_light_colors() {
        let css = generate_theme_css(SystemTheme::Light);
        // Light theme should have light background (white or very light)
        assert!(css.contains("#ffffff") || css.contains("#f8f9fa"));
        // And dark text
        assert!(css.contains("#0a0a0f"));
    }

    #[test]
    fn generate_theme_css_dark_has_dark_colors() {
        let css = generate_theme_css(SystemTheme::Dark);
        // Dark theme should have dark background
        assert!(css.contains("#0f0f1a") || css.contains("#161625"));
        // And light text
        assert!(css.contains("#f0eef6"));
    }
}
