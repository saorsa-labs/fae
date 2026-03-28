# Design System — Fae

## Product Context
- **What this is:** A personal AI companion for macOS that listens, remembers, and helps — like a knowledgeable friend always in the room.
- **Who it's for:** Mac users who want a thoughtful, voice-first assistant that runs entirely on their machine.
- **Space/industry:** Personal AI companion, on-device intelligence, privacy-first.
- **Project type:** Native macOS app (Swift + MLX, AppKit/SwiftUI hybrid).

## Aesthetic Direction
- **Direction:** Refined Organic — warm, literary, intimate. Fae is a presence, not a dashboard.
- **Decoration level:** Intentional — the orb provides all visual drama. UI elements use subtle frosted glass, soft borders, and gentle colour washes. No gradients on buttons, no emoji in headers, no generic system accent colours.
- **Mood:** A beautifully bound book sitting next to a candle. The orb is alive and breathing; the surrounding UI recedes to let it be the centre of attention.
- **Visual anchor:** The glowing amber orb rendered via Metal shaders (FogCloudOrb.metal, NebulaOrb.metal). All design decisions support, never compete with, the orb.

## Typography
- **Display/Headers:** Instrument Serif — warm, literary, pairs with the serif conversation bubbles. Use for settings window headers, section titles, and page titles. Replaces SF Pro Rounded in settings.
  - In SwiftUI: `.font(.custom("InstrumentSerif-Regular", size: 22))` (bundle the font, or fall back to `.system(.title, design: .serif)`)
- **Conversation bubbles:** `.system(size: 13, weight: .regular, design: .serif)` — already in use, keep exactly as-is.
- **UI/Labels:** SF Pro (system default) — maintain native macOS feel for controls, tabs, toggles, and form labels. No custom font here.
- **Data/Monospace:** SF Mono (system) or JetBrains Mono — for diagnostic values, model names, token counts, tool call previews. Must support tabular-nums.
- **Scale:** 42/24/22/16/13/12/11px. Headers are Instrument Serif, body is system serif at 13, labels are system sans at 11-12.

## Colour

### Surfaces
| Token | Hex | Usage |
|-------|-----|-------|
| `surface-base` | `#0F1013` | Conversation panel background, deep backgrounds |
| `surface-card` | `#1A1820` | Floating overlay cards, approval cards, custom panels. **NOT for Settings tabs** — Settings use `NSColor.windowBackgroundColor` to respect system light/dark mode. |
| `surface-elevated` | `#221F28` | Active tab backgrounds, hover states, elevated cards |
| `surface-frosted` | `rgba(26, 24, 32, 0.7)` | Frosted glass (`.ultraThinMaterial`) tint in compact mode |

### Fae Signature — Gold & Amber
| Token | Hex | Usage |
|-------|-----|-------|
| `fae-gold` | `#D4A934` | Primary accent: toggle on-state, primary buttons, active indicators, warm highlights |
| `fae-gold-text` | `#E6C05A` | Text variant for dark backgrounds (9.4:1 contrast) |
| `highland-amber` | `#C17F24` | Deeper amber for pressed states, secondary warmth |
| `cairngorm-topaz` | `#E6B85C` | Button hover states, code/monospace text colour, lighter warm accent |
| `islay-sunset` | `#E87D3E` | Urgent warm accent (speaking mode, notifications) |

### Cool Accent
| Token | Hex | Usage |
|-------|-----|-------|
| `heather-mist` | `#B4A8C4` | Fae's signature cool accent: borders, decorative elements, cursor colour |
| `heather-mist-text` | `#CEC4DC` | Text variant for dark backgrounds (10.2:1 contrast) |

### Chat Bubbles
| Token | Hex | Usage |
|-------|-----|-------|
| `user-bubble` | `#38476B` | User message background (blue-grey) |
| `user-bubble-border` | `rgba(89, 115, 166, 0.5)` | User message border |
| `fae-bubble` | `#3D334D` | Fae message background (lavender-grey) |
| `fae-bubble-border` | `rgba(180, 168, 196, 0.25)` | Fae message border |

### Scottish Landscape (decorative + semantic)
| Token | Hex | Text Variant | Contrast | Semantic Role |
|-------|-----|-------------|----------|---------------|
| `glen-green` | `#5F7F6F` | `#8FB8A2` | 7.0:1 | Success: pipeline ready, healthy, positive |
| `rowan-berry` | `#8B4653` | `#C4788A` | 5.0:1 | Error: disconnected, destructive, failed |
| `loch-grey-green` | `#7A9B8E` | — | — | Orb accent (listening mode) |
| `silver-mist` | `#C8D3D5` | — | — | Orb accent (calm states) |
| `moss-stone` | `#4A5D52` | — | — | Orb accent (nature tones) |
| `dawn-light` | `#E8DED2` | — | — | Orb accent (warm light) |
| `peat-earth` | `#3D3630` | — | — | Orb accent (deep earth) |

### Text Hierarchy
| Token | Value | Contrast on base | Usage |
|-------|-------|-----------------|-------|
| `text-primary` | `rgba(255, 255, 255, 0.92)` | 14.8:1 | Headings, body text, labels |
| `text-secondary` | `#CEC4DC` | 10.2:1 | Descriptions, subtitles, helper text |
| `text-muted` | `#9A90A8` | 5.2:1 | Section labels, metadata, toggle descriptions |
| `text-faint` | `#6E6580` | 2.8:1 | Decorative only — large text, borders, non-essential |
| `text-inverse` | `#0F1013` | — | Text on gold/amber buttons |

### Contrast Rule
Every colour used for readable text MUST pass WCAG AA (4.5:1) on its intended surface. Use the base hex values (`glen-green`, `rowan-berry`, etc.) for borders, backgrounds, and decorative elements. Use the `-text` variants for any text that someone needs to read.

### Dark Mode Strategy
Fae is dark-first. There is no light mode. The surface hierarchy (base → card → elevated) provides depth without a separate theme.

## Spacing
- **Base unit:** 8px
- **Density:** Comfortable — Fae is a companion, not a spreadsheet.
- **Scale:** `2xs(2)` `xs(4)` `sm(8)` `md(16)` `lg(24)` `xl(32)` `2xl(48)` `3xl(64)`
- **Section spacing:** 24px between content sections (already in use in settings).
- **Content padding:** 16px horizontal within cards and panels.
- **In SwiftUI:** Use these as raw CGFloat values. Example: `.padding(24)` for section spacing, `.padding(.horizontal, 16)` for content padding.

## Layout
- **Approach:** Intimate, not dense. Generous breathing room. Clear visual hierarchy.
- **Main window:** 120x120 collapsed (orb only), 340x500 compact (orb + subtitle + progress).
- **Conversation panel:** Independent NSPanel, width ≈ 380px.
- **Settings:** TabView, standard macOS settings window proportions.
- **Border radius:** Hierarchical scale:
  - `sm: 6px` — buttons, small tags, inline code blocks
  - `md: 12px` — status cards, form inputs, dropdown menus
  - `lg: 16px` — message bubbles, approval cards, content panels
  - `xl: 20px` — main window, settings window, conversation panel
  - `full: 9999px` — toggles, avatar circles, pill badges

## Motion
- **Approach:** Intentional — the orb has sophisticated motion (breathing, morphing, sparkles via Metal shaders). Secondary UI echoes it with subtlety, never competes.
- **Easing:**
  - `enter:` ease-out (decelerate in) — `.easeOut` / `cubic-bezier(0, 0, 0.2, 1)`
  - `exit:` ease-in (accelerate out) — `.easeIn` / `cubic-bezier(0.4, 0, 1, 1)`
  - `move:` ease-in-out — `.easeInOut` / `cubic-bezier(0.4, 0, 0.2, 1)`
- **Duration:**
  - `micro: 80ms` — toggle switches, hover highlights
  - `short: 200ms` — card transitions, state changes (`.spring(duration: 0.2)`)
  - `medium: 350ms` — panel slides, overlay entrances (`.spring(duration: 0.3)`)
  - `long: 500ms` — window mode transitions, orb palette shifts (`.easeInOut(duration: 0.5)`)
- **Existing patterns to preserve:**
  - Approval overlays: `.spring(duration: 0.3)` with `.move(edge: .bottom).combined(with: .opacity)`
  - Streaming cursor: `.linear(duration: 0.5).repeatForever(autoreverses: true)`
  - Window mode: `.easeInOut(duration: 0.5)`

## Anti-Patterns (never use)
- Purple-blue gradient circles (the settings header had one — replace with orb icon)
- Emoji as UI elements in headers or labels (use SF Symbols or the orb mark)
- System accent colours (`.blue`, `.green`, `.orange`) — use the Scottish palette instead
- Generic system `windowBackgroundColor` in panels that should feel like Fae
- `SF Pro Rounded` for display text — use Instrument Serif
- Decorative gradients on buttons
- Any text colour below 4.5:1 contrast on its background

## Decisions Log
| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-03-28 | Initial design system created | Codified existing orb + conversation design language, extended to settings. Created by /design-consultation. |
| 2026-03-28 | Dual-layer colour system (base + text variants) | Scottish palette colours too dark for readable text on dark backgrounds. Base hex for decoration, lightened `-text` variants for readable text. All pass WCAG AA. |
| 2026-03-28 | Instrument Serif for display typography | Matches the literary quality of serif conversation bubbles. Warm without being decorative. |
| 2026-03-28 | No light mode | Fae is dark-first by identity. The orb is designed for dark backgrounds. Surface hierarchy provides depth. |
