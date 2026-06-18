import SwiftUI

/// Design-token surface for the Convert SDK demo app.
///
/// Mirrors `ux/DESIGN.md`: a restrained Convert brand delta over the native
/// iOS system. Colors resolve light/dark via the asset catalog (each token is
/// a `<Name>.colorset` with a base and a `dark` luminosity appearance), so the
/// values are never hardcoded literals here — the catalog owns the mode swap.
///
/// Typography is platform-native (SF Pro Dynamic Type + SF Mono via
/// `.monospaced`), so no font tokens are declared; a `monospacedBody` helper is
/// provided for the data/log cells that DESIGN.md routes to SF Mono.
///
/// Colors are exposed as computed `static var` (not stored `static let`) so the
/// type stays clean under `SWIFT_STRICT_CONCURRENCY: complete`: SwiftUI's
/// `Color` is not `Sendable` on every SDK, and a stored non-`Sendable` static
/// would require global-actor isolation. A computed property has no stored
/// global state and sidesteps that requirement entirely.
enum ConvertTheme {

    // MARK: - Colors (asset-catalog resolved, light/dark)

    /// Convert Blue — the one brand accent. App-wide `.tint`, primary actions,
    /// selected tab, links. Light `#0066ff` / dark `#4da3ff`.
    static var accent: Color { Color("BrandAccent", bundle: .main) }

    /// Pressed state of the accent button. `#2341e0` in both modes.
    static var accentPressed: Color { Color("BrandAccentPressed", bundle: .main) }

    /// The only accent fill — selected-row / subtle-highlight background.
    static var accentSoft: Color { Color("BrandAccentSoft", bundle: .main) }

    /// Success hue for icons, leading rules, and tints (UI element, >=3:1).
    static var success: Color { Color("BrandSuccess", bundle: .main) }

    /// Soft fill behind a success chip's text.
    static var successSoft: Color { Color("BrandSuccessSoft", bundle: .main) }

    /// Darkened success chip label (AA text on `successSoft`).
    static var successText: Color { Color("BrandSuccessText", bundle: .main) }

    /// Soft fill behind a warn chip's text.
    static var warnSoft: Color { Color("BrandWarnSoft", bundle: .main) }

    /// Darkened warn chip label (AA text on `warnSoft`).
    static var warnText: Color { Color("BrandWarnText", bundle: .main) }

    /// Error hue for icons, leading rules, and tints (UI element, >=3:1).
    static var error: Color { Color("BrandError", bundle: .main) }

    /// Soft fill behind an error chip's text.
    static var errorSoft: Color { Color("BrandErrorSoft", bundle: .main) }

    /// Darkened error chip label (AA text on `errorSoft`).
    static var errorText: Color { Color("BrandErrorText", bundle: .main) }

    /// Brand ink — reserved for the fixed-color launch / logo lockup context.
    /// In-app text uses a system label color instead.
    static var ink: Color { Color("BrandInk", bundle: .main) }

    // MARK: - Radii (DESIGN.md `rounded`)

    /// Small fills and banners.
    static let radiusSm: CGFloat = 8

    /// Cards and grouped panels.
    static let radiusMd: CGFloat = 12

    /// Full capsule — status badges.
    static let radiusFull: CGFloat = 9999

    // MARK: - Spacing (DESIGN.md 8-pt grid: 4 / 8 / 12 / 16 / 20 / 24 / 32)

    static let space1: CGFloat = 4
    static let space2: CGFloat = 8
    static let space3: CGFloat = 12
    static let space4: CGFloat = 16
    static let space5: CGFloat = 20
    static let space6: CGFloat = 24
    static let space7: CGFloat = 32

    // MARK: - Typography helper

    /// SF Mono at the Dynamic-Type-scaled body size — for event payloads, log
    /// lines, and the masked SDK key (DESIGN.md `typography.mono`).
    static func monospacedBody() -> Font {
        .system(.body, design: .monospaced)
    }
}
