---
name: apple-ui-design
description: Apple-inspired clean, minimal, premium UI design for SwiftUI/AppKit. Use when building or reviewing native macOS/iOS interfaces requiring exceptional UX, clean aesthetics, or Apple-like polish. Triggers on: clean UI, modern design, Apple style, minimal, premium, user-friendly, UX.
---

# Apple UI Design (SwiftUI / AppKit)

Apple-inspired clean, minimal, premium UI design system, expressed in native SwiftUI/AppKit — not CSS. There is no DOM here; every rule below maps to a `View` modifier, a `Font`, or a system `Color`.

## When to Use

- Building modern interfaces requiring exceptional UX
- Creating clean, minimal aesthetics
- Implementing Apple-like polish and animations
- Designing premium user experiences
- Reviewing SwiftUI/AppKit UI for design quality

## Workflow

### Step 1: Apply Typography System

Use `Font` text styles (which track Dynamic Type / accessibility text size), not fixed point sizes, unless deliberately overriding weight for a specific hierarchy level.

### Step 2: Apply Color Philosophy

Use semantic system `Color`/`NSColor` tokens so light/dark mode and accessibility contrast settings are automatic — never hardcode hex values for text or backgrounds.

### Step 3: Apply Spacing System

Follow an 4/8/12/16/24/32/48pt rhythm via `padding`/`spacing`, matching the platform's native metrics (see Spacing below).

### Step 4: Verify Checklist

Ensure touch/click targets, contrast, and animations meet standards (see Checklist below).

---

## Core Principles

1. **Clarity** — content is king, UI disappears
2. **Deference** — UI serves content, never competes with it
3. **Depth** — layering (materials, shadow, z-order) creates hierarchy, not borders

## Typography

Prefer semantic text styles over raw sizes:

```swift
Text("Section Title").font(.title2.weight(.semibold))   // section headers
Text(body).font(.body)                                   // readable content
Text(caption).font(.caption).foregroundStyle(.secondary)  // secondary info
Text(hero).font(.largeTitle.weight(.bold))                // hero statements
```

If a design calls for an exact hierarchy independent of Dynamic Type, use `.system(size:weight:)` sparingly and only for chrome (not user content).

## Color Philosophy

Never hardcode `Color(hex:)`/`Color(red:green:blue:)` for UI chrome — use the system semantic palette so dark mode and contrast/accessibility settings are handled for free:

```swift
// macOS (NSColor-backed) — see NoteSide/Core/UI/NoteSideTheme.swift for
// a worked example of collecting these into one enum per project.
Color(nsColor: .windowBackgroundColor)     // primary background
Color(nsColor: .controlBackgroundColor)    // content surface
Color(nsColor: .labelColor)                // primary text
Color(nsColor: .secondaryLabelColor)       // secondary text
Color(nsColor: .separatorColor)            // hairlines/borders
Color(nsColor: .controlAccentColor)        // accent (respects user's pick)

// Cross-platform (iOS/macOS) shorthand when NSColor isn't available:
Color.primary
Color.secondary
Color(.systemBackground)   // iOS only
```

Collect a project's tokens into one `enum`/namespace (as `NoteSideTheme` does) rather than scattering raw system-color calls through views — one place to retint or adjust contrast later.

## Spacing System

Point-based, not pixel-based — SwiftUI `padding`/`spacing`/`frame` values are already resolution-independent:

```swift
enum Spacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 16
    static let lg: CGFloat = 24
    static let xl: CGFloat = 48
    static let xxl: CGFloat = 96   // section gaps
}
```

## Key Patterns

### Cards / Surfaces

Use a `RoundedRectangle` fill + hairline stroke, or a native `Material` for translucency — never a manual `box-shadow`-style stack of separate shadow layers.

```swift
content
    .padding(16)
    .background(
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(NoteSideTheme.contentBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(NoteSideTheme.border.opacity(0.8), lineWidth: 1)
            )
    )
```

For real translucency/blur, use a `Material` rather than approximating `backdrop-filter`:

```swift
content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
```

### Buttons

Prefer the built-in button styles/roles over reinventing chrome — they already carry the right hover/press feedback and accessibility behavior on each platform:

```swift
Button("Primary Action") { ... }
    .buttonStyle(.borderedProminent)
    .controlSize(.large)

Button("Secondary") { ... }
    .buttonStyle(.bordered)
```

Only hand-roll button chrome (custom `RoundedRectangle` background, `.buttonStyle(.plain)`) when the built-in styles genuinely can't express the design — and if you do, keep the pill/rounded-rect radius and scale-on-press micro-interaction below.

### Subtle Animations

```swift
withAnimation(.easeOut(duration: 0.2)) {
    isExpanded.toggle()
}

// Micro-interaction on press
.scaleEffect(isPressed ? 0.98 : 1.0)
.animation(.easeOut(duration: 0.15), value: isPressed)
```

Always check `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` (macOS) / `UIAccessibility.isReduceMotionEnabled` (iOS) before animating position/scale, and fall back to a plain fade — see `PanelAnimation.prefersReducedMotion` in this codebase for the existing helper.

## UX Rules

| Do | Don't |
|----|-------|
| Generous whitespace | Cramped layouts |
| One primary action per screen | Multiple competing CTAs |
| Progressive disclosure | Everything visible at once |
| Subtle, interruptible feedback | Jarring or blocking animations |
| System fonts, semantic colors | Decorative fonts, hardcoded hex |
| Native controls (`Button`, `Toggle`, `.bordered*`) | Reimplemented chrome that fights platform conventions |

## Checklist

- [ ] Click/touch targets ≥ 44×44pt (macOS controls can be smaller, but interactive rows should still hit this)
- [ ] Text contrast meets WCAG AA (4.5:1) against its background in both light and dark mode
- [ ] Reading-width content stays comfortably narrow (~600–680pt) even in wide windows
- [ ] Spacing follows one consistent rhythm, not ad-hoc magic numbers
- [ ] Verified in both light and dark mode (`NoteSideTheme`/system colors, not hardcoded)
- [ ] Animations respect Reduce Motion and stay at a native, non-janky frame rate
- [ ] Verified with the XCUITest suite (`NoteSideUITests`) or a manual run, not just a compile check — see the README's Testing section
