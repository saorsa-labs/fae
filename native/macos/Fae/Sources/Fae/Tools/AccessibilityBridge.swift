import AppKit
import ApplicationServices
import Foundation

/// Wraps macOS Accessibility API (AXUIElement) for UI interaction.
///
/// Used by computer use tools (read_screen, click, type_text, find_element)
/// to query and interact with application UI elements.
enum AccessibilityBridge {

    /// A discovered UI element with its properties and location.
    struct UIElement: Sendable {
        let role: String
        let title: String?
        let value: String?
        let frame: CGRect
        let isEnabled: Bool
        let pid: pid_t
        let elementIndex: Int
        let appName: String?
        let bundleIdentifier: String?
        let isSecureInput: Bool
    }

    /// Snapshot of the currently focused accessibility element.
    struct FocusedElementSnapshot: Sendable {
        let role: String
        let title: String?
        let value: String?
        let pid: pid_t
        let appName: String?
        let bundleIdentifier: String?
        let isSecureInput: Bool
    }

    enum BridgeError: LocalizedError {
        case accessibilityNotEnabled
        case appNotFound(String)
        case elementQueryFailed
        case actionFailed(String)

        var errorDescription: String? {
            switch self {
            case .accessibilityNotEnabled:
                return "Accessibility access not enabled. Grant access in System Settings > Privacy & Security > Accessibility."
            case .appNotFound(let name):
                return "Application '\(name)' not found or not running."
            case .elementQueryFailed:
                return "Failed to query UI elements."
            case .actionFailed(let reason):
                return "Action failed: \(reason)"
            }
        }
    }

    // MARK: - Permission Checks

    private static let deniedAppNames: Set<String> = [
        "System Settings",
        "Keychain Access",
        "SecurityAgent",
    ]

    private static let deniedBundleIDs: Set<String> = [
        "com.apple.systempreferences",
        "com.apple.keychainaccess",
        "com.apple.SecurityAgent",
    ]

    /// Whether Accessibility API access is currently granted.
    static func isAccessibilityEnabled() -> Bool {
        AXIsProcessTrusted()
    }

    /// Request Accessibility access (shows system prompt if not already granted).
    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    /// Returns true when the target app is frontmost.
    static func isFrontmostApp(pid: pid_t) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    /// Returns true when the target app is denylisted for automation.
    static func isDeniedAutomationTarget(pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        if let name = app.localizedName, deniedAppNames.contains(name) {
            return true
        }
        if let bundleID = app.bundleIdentifier, deniedBundleIDs.contains(bundleID) {
            return true
        }
        return false
    }

    // MARK: - Element Discovery

    /// Query all interactive UI elements, optionally filtered to a specific app.
    ///
    /// - Parameter appName: If provided, only query elements from this app.
    ///   If nil, queries elements from the frontmost application.
    /// - Returns: Array of discovered UI elements with sequential indices.
    static func queryElements(appName: String?) throws -> [UIElement] {
        guard isAccessibilityEnabled() else {
            throw BridgeError.accessibilityNotEnabled
        }

        let targetApp = try resolveTargetApp(appName: appName)

        let targetPid = targetApp.processIdentifier
        let appElement = AXUIElementCreateApplication(targetPid)
        var elements: [UIElement] = []
        var index = 0

        collectElements(
            from: appElement,
            pid: targetPid,
            appName: targetApp.localizedName,
            bundleIdentifier: targetApp.bundleIdentifier,
            elements: &elements,
            index: &index,
            depth: 0
        )

        return elements
    }

    // MARK: - Actions

    /// Press/activate an element at the given frame location in the given process.
    ///
    /// Uses Accessibility API `AXUIElementPerformAction` with `kAXPressAction`.
    /// Falls back to CGEvent mouse click if the accessibility action fails.
    static func pressElement(pid: pid_t, frame: CGRect) throws {
        guard isAccessibilityEnabled() else {
            throw BridgeError.accessibilityNotEnabled
        }

        let appElement = AXUIElementCreateApplication(pid)
        if let element = findElement(in: appElement, near: frame) {
            let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
            if result == .success { return }
        }

        // Fallback: CGEvent click at center of frame.
        let center = CGPoint(x: frame.midX, y: frame.midY)
        performClick(at: center)
    }

    /// Set the value of an element at the given frame location.
    ///
    /// Uses Accessibility API `AXUIElementSetAttributeValue` with `kAXValueAttribute`.
    static func setValue(_ value: String, pid: pid_t, frame: CGRect) throws {
        guard isAccessibilityEnabled() else {
            throw BridgeError.accessibilityNotEnabled
        }

        let appElement = AXUIElementCreateApplication(pid)
        guard let element = findElement(in: appElement, near: frame) else {
            throw BridgeError.actionFailed("Could not find element near \(frame)")
        }

        // Focus the element first.
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, true as CFTypeRef)

        let result = AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            value as CFTypeRef
        )
        guard result == .success else {
            throw BridgeError.actionFailed("Failed to set value (error \(result.rawValue))")
        }
    }

    /// Returns the focused accessibility element for a specific app or PID.
    static func focusedElementSnapshot(appName: String? = nil, pid: pid_t? = nil) throws -> FocusedElementSnapshot? {
        guard isAccessibilityEnabled() else {
            throw BridgeError.accessibilityNotEnabled
        }

        let targetApp: NSRunningApplication
        if let pid {
            guard let app = NSRunningApplication(processIdentifier: pid) else {
                throw BridgeError.actionFailed("Could not resolve application for pid \(pid)")
            }
            targetApp = app
        } else {
            targetApp = try resolveTargetApp(appName: appName)
        }

        let appElement = AXUIElementCreateApplication(targetApp.processIdentifier)
        let focusedObject = attribute(appElement, kAXFocusedUIElementAttribute)
            ?? attribute(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute)
        guard let focusedElement = axElement(from: focusedObject) else {
            return nil
        }

        let role = attribute(focusedElement, kAXRoleAttribute) as? String ?? ""
        let title = attribute(focusedElement, kAXTitleAttribute) as? String
        let value = attribute(focusedElement, kAXValueAttribute) as? String
        let subrole = attribute(focusedElement, kAXSubroleAttribute) as? String
        let secure = (subrole == (kAXSecureTextFieldSubrole as String))
            || (role == (kAXTextFieldRole as String) && (title ?? "").lowercased().contains("password"))

        return FocusedElementSnapshot(
            role: role,
            title: title,
            value: value,
            pid: targetApp.processIdentifier,
            appName: targetApp.localizedName,
            bundleIdentifier: targetApp.bundleIdentifier,
            isSecureInput: secure
        )
    }

    // MARK: - Private Helpers

    private static func resolveTargetApp(appName: String?) throws -> NSRunningApplication {
        if let appName {
            guard let app = NSWorkspace.shared.runningApplications.first(where: {
                $0.localizedName?.localizedCaseInsensitiveContains(appName) == true
            }) else {
                throw BridgeError.appNotFound(appName)
            }
            return app
        }

        guard let frontmost = NSWorkspace.shared.frontmostApplication else {
            throw BridgeError.elementQueryFailed
        }
        return frontmost
    }

    /// Recursively collect interactive UI elements from an accessibility hierarchy.
    private static func collectElements(
        from element: AXUIElement,
        pid: pid_t,
        appName: String?,
        bundleIdentifier: String?,
        elements: inout [UIElement],
        index: inout Int,
        depth: Int
    ) {
        // Limit traversal depth to prevent infinite recursion.
        guard depth < 15 else { return }
        // Cap total elements to prevent excessive scanning.
        guard elements.count < 500 else { return }

        let role = attribute(element, kAXRoleAttribute) as? String ?? ""
        let title = attribute(element, kAXTitleAttribute) as? String
        let value = attribute(element, kAXValueAttribute) as? String
        let subrole = attribute(element, kAXSubroleAttribute) as? String
        let isEnabled = (attribute(element, kAXEnabledAttribute) as? Bool) ?? true

        // Get position and size to compute frame.
        var frame = CGRect.zero
        if let point = cgPoint(from: attribute(element, kAXPositionAttribute)) {
            frame.origin = point
        }
        if let size = cgSize(from: attribute(element, kAXSizeAttribute)) {
            frame.size = size
        }

        // Include interactive elements (buttons, text fields, checkboxes, links, etc.).
        let interactiveRoles: Set<String> = [
            kAXButtonRole as String,
            kAXCheckBoxRole as String,
            kAXRadioButtonRole as String,
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXPopUpButtonRole as String,
            kAXMenuButtonRole as String,
            kAXComboBoxRole as String,
            kAXSliderRole as String,
            kAXIncrementorRole as String,
            "AXLink",
            kAXTabGroupRole as String,
            kAXMenuItemRole as String,
        ]

        if interactiveRoles.contains(role), frame.width > 0, frame.height > 0 {
            let secure = (subrole == (kAXSecureTextFieldSubrole as String))
                || (role == (kAXTextFieldRole as String) && (title ?? "").lowercased().contains("password"))
            elements.append(UIElement(
                role: role,
                title: title,
                value: value,
                frame: frame,
                isEnabled: isEnabled,
                pid: pid,
                elementIndex: index,
                appName: appName,
                bundleIdentifier: bundleIdentifier,
                isSecureInput: secure
            ))
            index += 1
        }

        // Recurse into children.
        guard let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] else {
            return
        }
        for child in children {
            collectElements(
                from: child,
                pid: pid,
                appName: appName,
                bundleIdentifier: bundleIdentifier,
                elements: &elements,
                index: &index,
                depth: depth + 1
            )
        }
    }

    /// Read an accessibility attribute from an element.
    private static func attribute(_ element: AXUIElement, _ attr: String) -> AnyObject? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attr as CFString, &value)
        return result == .success ? value : nil
    }

    private static func axElement(from value: AnyObject?) -> AXUIElement? {
        guard let value else { return nil }
        let cfValue = value as CFTypeRef
        guard CFGetTypeID(cfValue) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func cgPoint(from value: AnyObject?) -> CGPoint? {
        guard let value else { return nil }
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgPoint else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    private static func cgSize(from value: AnyObject?) -> CGSize? {
        guard let value else { return nil }
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgSize else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }

    /// Find the closest element to a target frame in the accessibility tree.
    private static func findElement(in root: AXUIElement, near target: CGRect) -> AXUIElement? {
        var bestMatch: AXUIElement?
        var bestDistance: CGFloat = .infinity

        searchTree(root, target: target, bestMatch: &bestMatch, bestDistance: &bestDistance, depth: 0)

        return bestMatch
    }

    /// Recursive tree search for the element closest to a target frame.
    private static func searchTree(
        _ element: AXUIElement,
        target: CGRect,
        bestMatch: inout AXUIElement?,
        bestDistance: inout CGFloat,
        depth: Int
    ) {
        guard depth < 15 else { return }

        // Check this element's frame.
        var frame = CGRect.zero
        if let point = cgPoint(from: attribute(element, kAXPositionAttribute)) {
            frame.origin = point
        }
        if let size = cgSize(from: attribute(element, kAXSizeAttribute)) {
            frame.size = size
        }

        if frame.width > 0, frame.height > 0 {
            let dist = hypot(frame.midX - target.midX, frame.midY - target.midY)
            if dist < bestDistance {
                bestDistance = dist
                bestMatch = element
            }
        }

        // Recurse.
        guard let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] else {
            return
        }
        for child in children {
            searchTree(child, target: target, bestMatch: &bestMatch, bestDistance: &bestDistance, depth: depth + 1)
        }
    }

    /// Perform a mouse click at the given screen coordinates using CGEvent.
    private static func performClick(at point: CGPoint) {
        let mouseDown = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: point,
            mouseButton: .left
        )
        let mouseUp = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseUp,
            mouseCursorPosition: point,
            mouseButton: .left
        )
        mouseDown?.post(tap: .cghidEventTap)
        mouseUp?.post(tap: .cghidEventTap)
    }
}
