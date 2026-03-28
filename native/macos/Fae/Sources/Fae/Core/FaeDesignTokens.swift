import SwiftUI

// MARK: - Fae Design System Tokens
// See DESIGN.md for rationale and usage rules.
// Base hex values → borders, backgrounds, decorative.
// -Text variants → readable text on dark surfaces (WCAG AA minimum 4.5:1).

enum FaeDesign {
    // MARK: Surfaces

    static let surfaceBase = Color(red: 0.059, green: 0.063, blue: 0.075)           // #0F1013
    static let surfaceCard = Color(red: 0.102, green: 0.094, blue: 0.125)           // #1A1820
    static let surfaceElevated = Color(red: 0.133, green: 0.122, blue: 0.157)       // #221F28
    static let surfaceFrosted = Color(red: 0.102, green: 0.094, blue: 0.125).opacity(0.7)

    // MARK: Fae Signature — Gold & Amber

    static let faeGold = Color(red: 0.831, green: 0.663, blue: 0.204)               // #D4A934
    static let faeGoldText = Color(red: 0.902, green: 0.753, blue: 0.353)           // #E6C05A
    static let highlandAmber = Color(red: 0.757, green: 0.498, blue: 0.141)         // #C17F24
    static let cairngormTopaz = Color(red: 0.902, green: 0.722, blue: 0.361)        // #E6B85C
    static let islaySunset = Color(red: 0.910, green: 0.490, blue: 0.243)           // #E87D3E

    // MARK: Cool Accent

    static let heatherMist = Color(red: 0.706, green: 0.659, blue: 0.769)           // #B4A8C4
    static let heatherMistText = Color(red: 0.808, green: 0.769, blue: 0.863)       // #CEC4DC
    static let heatherMistBorder = Color(red: 0.706, green: 0.659, blue: 0.769).opacity(0.25)
    static let heatherMistBorderHover = Color(red: 0.706, green: 0.659, blue: 0.769).opacity(0.40)

    // MARK: Scottish Semantic — Base (borders, backgrounds, decorative)

    static let glenGreen = Color(red: 0.373, green: 0.498, blue: 0.435)             // #5F7F6F
    static let rowanBerry = Color(red: 0.545, green: 0.275, blue: 0.325)            // #8B4653
    static let lochGreyGreen = Color(red: 0.478, green: 0.608, blue: 0.557)         // #7A9B8E
    static let silverMist = Color(red: 0.784, green: 0.827, blue: 0.835)            // #C8D3D5
    static let mossStone = Color(red: 0.290, green: 0.365, blue: 0.322)             // #4A5D52
    static let dawnLight = Color(red: 0.910, green: 0.871, blue: 0.824)             // #E8DED2
    static let peatEarth = Color(red: 0.239, green: 0.212, blue: 0.188)             // #3D3630

    // MARK: Scottish Semantic — Text (lightened for WCAG AA on dark surfaces)

    static let glenGreenText = Color(red: 0.561, green: 0.722, blue: 0.635)         // #8FB8A2 — 7.0:1
    static let rowanBerryText = Color(red: 0.769, green: 0.471, blue: 0.541)        // #C4788A — 5.0:1

    // MARK: Text Hierarchy

    static let textPrimary = Color.white.opacity(0.92)                               // 14.8:1
    static let textSecondary = Color(red: 0.808, green: 0.769, blue: 0.863)         // #CEC4DC — 10.2:1
    static let textMuted = Color(red: 0.604, green: 0.565, blue: 0.659)             // #9A90A8 — 5.2:1
    static let textFaint = Color(red: 0.431, green: 0.396, blue: 0.502)             // #6E6580 — decorative

    // MARK: Semantic Mapping (convenience aliases for status indicators)

    /// Success states: pipeline ready, enrolled, healthy, cached, connected
    static let statusSuccess = glenGreenText
    /// Warning states: loading, degraded, needs attention
    static let statusWarning = faeGoldText
    /// Error states: failed, disconnected, destructive, missing
    static let statusError = rowanBerryText
    /// Info states: background activity, neutral informational
    static let statusInfo = heatherMistText

    /// Success background tint for cards/badges
    static let statusSuccessBg = glenGreen.opacity(0.15)
    /// Warning background tint
    static let statusWarningBg = faeGold.opacity(0.10)
    /// Error background tint
    static let statusErrorBg = rowanBerry.opacity(0.15)
    /// Info background tint
    static let statusInfoBg = heatherMist.opacity(0.10)

    // MARK: Buttons

    /// Primary action button background (Allow, Save, Confirm)
    static let buttonPrimary = faeGold
    /// Primary button text
    static let buttonPrimaryText = Color(red: 0.059, green: 0.063, blue: 0.075)     // #0F1013
    /// Destructive button background
    static let buttonDestructiveBg = rowanBerry.opacity(0.20)
    /// Destructive button text
    static let buttonDestructiveText = rowanBerryText
    /// Ghost/secondary button border
    static let buttonGhostBorder = heatherMistBorder
}
