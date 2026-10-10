import SwiftUI

// MARK: - Glass
//
// The app's one translucency system. Every surface belongs to exactly one of three layers, back to front:
//
// 1. Ground: `canvas`, opaque, full-bleed.
// 2. Content: the transcript's bubbles, tool cards, reasoning rule and code blocks, opaque in the Desktop palette. Never glass, because a word read through another word is the failure this file exists to prevent.
// 3. Chrome: the conversation's top bar and bottom dock, and the controls that float over content. Glass.
//
// Content may pass behind chrome; chrome never passes behind content. Sheets, the approval prompt, settings and the hub are opaque by rule: they carry forms and decisions, and a decision is never read through another one.
//
// Three kinds of glass, deliberately:
// - The top edge on iOS 26 is the system's: the transcript's scroll view runs under the bar, the bar paints nothing, and the scroll view's own soft scroll-edge effect frosts and fades the conversation under Back and `⋯`.
// - A chrome plane (the bottom dock everywhere, and the top edge below iOS 26) is a `Material` under a theme tint. The tint carries legibility on its own and the frost is texture, which is Desktop's rule for the composer the phone mirrors (`styles.css`, `--composer-fill`: the card at 88 % over a 12 px blur). Never `glassEffect`: a full-width `glassEffect` beneath the transcript reproduced BUG-016 (FEAT-024, runs `f024-ui1` to `f024-ui4`).
// - A floating control (scroll to latest, the media viewer's buttons) is the system's Liquid Glass on iOS 26 and a material disc below it.

/// How glass is drawn on the OS the app is running on: the system's (scroll-edge effect, `glassEffect`) or the app's own material. The deployment target is iOS 17.0 and both system effects arrived in iOS 26, so every glass call site resolves through this rather than through an availability check of its own.
enum GlassRendering: Equatable {
    /// iOS 26 and up: the system's Liquid Glass.
    case liquidGlass
    /// iOS 17 to 25, or any OS with the fallback forced: a material disc with a rim.
    case material

    /// The first major release with `glassEffect`.
    static let liquidGlassMinimumMajorVersion = 26

    static func resolve(osMajorVersion: Int, forcesFallback: Bool = false) -> GlassRendering {
        guard !forcesFallback else { return .material }
        return osMajorVersion >= liquidGlassMinimumMajorVersion ? .liquidGlass : .material
    }

    static var current: GlassRendering {
        resolve(
            osMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
            forcesFallback: GlassFixtures.forcesFallback
        )
    }
}

/// The glass fixture for the screenshot harness.
enum GlassFixtures {
    /// `-hermesGlassFallback`: draws the iOS 17 to 25 path on an iOS 26 simulator, so the fallback can be captured where no older runtime is installed. Always false outside DEBUG.
    static var forcesFallback: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-hermesGlassFallback")
        #else
        false
        #endif
    }
}

/// The numbers the glass is built from. Kept out of `HermesTokens`, which compiles into the Live Activity extension, where nothing is glass.
enum GlassMetrics {
    /// How much of the theme's canvas is laid over a chrome plane's frost. High enough that the plane reads as the theme rather than the system's grey and that words on it hold against a transcript passing behind; low enough that the transcript is still seen moving under it.
    static let chromeTintOpacity: Double = 0.6
    /// The floor `chromeTintOpacity` may not go under: below it the composer's placeholder and the dock's rows start competing with the blurred text behind them.
    static let chromeTintFloor: Double = 0.5
    /// The soft lift a plane's free edge casts onto the content passing behind it.
    static let planeShadowRadius: CGFloat = 10
    /// How far the top plane reaches up from the top of the conversation: past the tallest bar plus status bar any iPhone draws (54 + 62 pt), so it always fills the region above the content and runs off the top of the screen. Measured rather than read, because a `GeometryReader` that ignores the safe area reports no inset to measure with.
    static let topPlaneReach: CGFloat = 240
    /// The canvas share a floating Liquid Glass control is tinted with.
    static let floatingTintOpacity: Double = 0.25
    /// How far down a plane's sides the rim runs before it has faded out, as a share of the plane's height.
    static let rimFadeLength: CGFloat = 0.3
    /// The composer well's fill on the dock: Desktop's `--composer-fill`, the card at 88 % (`apps/desktop/src/styles.css`, `[data-slot='composer-root']`). The fill is what the field is read against; the plate's frost shows through the rest.
    static let composerFillOpacity: Double = 0.88
}

/// What each glass surface is tinted with, resolved from the live skin so the frost takes the theme's colour rather than the system's.
struct GlassTokens {
    /// Laid over a chrome plane's frost.
    let chromeTint: Color
    /// The specular edge: the one line a plane is allowed, along the side that faces content.
    let rim: Color
    /// The lift under a plane's free edge or a floating control.
    let shadow: Color
    /// Carried by a floating Liquid Glass control.
    let floatingTint: Color

    init(_ t: HermesTokens, scheme: ColorScheme) {
        chromeTint = t.canvas.opacity(GlassMetrics.chromeTintOpacity)
        rim = Color.white.opacity(scheme == .dark ? 0.14 : 0.7)
        shadow = Color.black.opacity(scheme == .dark ? 0.45 : 0.07)
        floatingTint = t.canvas.opacity(GlassMetrics.floatingTintOpacity)
    }
}

// MARK: - Chrome planes

/// A frosted chrome plane anchored to one edge of the screen: frost, theme tint, a rim along the edge that faces content, and a soft lift onto the content passing behind it. Draws nothing a touch can land on.
struct GlassPlaneBackground: View {
    @Environment(\.hermes) private var t
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var displayScale

    /// The screen edge the plane is anchored to; its rounded corners and its rim are on the other side.
    let anchoredTo: VerticalEdge
    let cornerRadius: CGFloat

    var body: some View {
        let glass = GlassTokens(t, scheme: scheme)
        let plate = shape
        // Never `.compositingGroup()`, `.drawingGroup()` or `.shadow` on anything holding the material: each renders the group offscreen, where the material has no backdrop to blur and paints as a flat fill — the slab this plane replaces.
        ZStack {
            plate.fill(ChatChromeMaterial.current.frost)
            plate.fill(glass.chromeTint)
        }
        // The rim fades out down the plane's sides, so it reads as the leading edge of a sheet of glass and not as a frame around it.
        .overlay {
            plate.stroke(
                LinearGradient(
                    colors: [glass.rim, glass.rim.opacity(0)],
                    startPoint: freeEdgePoint,
                    endPoint: rimFadeEndPoint
                ),
                lineWidth: 1 / displayScale
            )
        }
        // The lift: a gradient laid on the content just past the free edge, standing in for a shadow the material cannot carry.
        .overlay(alignment: anchoredTo == .bottom ? .top : .bottom) {
            LinearGradient(
                colors: [glass.shadow, glass.shadow.opacity(0)],
                startPoint: anchoredTo == .bottom ? .bottom : .top,
                endPoint: anchoredTo == .bottom ? .top : .bottom
            )
            .frame(height: GlassMetrics.planeShadowRadius)
            .offset(y: anchoredTo == .bottom ? -GlassMetrics.planeShadowRadius : GlassMetrics.planeShadowRadius)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Which corners are rounded: only the two on the edge that faces content. The anchored edge runs off the screen, where a rounded corner would show the ground through a notch.
    static func corners(anchoredTo edge: VerticalEdge, cornerRadius: CGFloat) -> (top: CGFloat, bottom: CGFloat) {
        edge == .bottom ? (top: cornerRadius, bottom: 0) : (top: 0, bottom: cornerRadius)
    }

    private var shape: UnevenRoundedRectangle {
        let corners = Self.corners(anchoredTo: anchoredTo, cornerRadius: cornerRadius)
        return UnevenRoundedRectangle(
            topLeadingRadius: corners.top,
            bottomLeadingRadius: corners.bottom,
            bottomTrailingRadius: corners.bottom,
            topTrailingRadius: corners.top,
            style: .continuous
        )
    }

    private var freeEdgePoint: UnitPoint {
        anchoredTo == .bottom ? .top : .bottom
    }

    private var rimFadeEndPoint: UnitPoint {
        let fade = GlassMetrics.rimFadeLength
        return anchoredTo == .bottom ? UnitPoint(x: 0.5, y: fade) : UnitPoint(x: 0.5, y: 1 - fade)
    }
}

// MARK: - Floating controls

extension View {
    /// A control floating over content: Liquid Glass on iOS 26, a material disc with a rim below it. `tint` overrides the skin's canvas for a control that floats over media rather than over the transcript.
    func glassFloating<S: Shape>(in shape: S, tint: Color? = nil) -> some View {
        modifier(GlassFloatingModifier(shape: shape, tint: tint))
    }
}

struct GlassFloatingModifier<S: Shape>: ViewModifier {
    @Environment(\.hermes) private var t
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var displayScale

    let shape: S
    let tint: Color?

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            if GlassRendering.current == .liquidGlass {
                content.glassEffect(.regular.tint(tintColor).interactive(), in: shape)
            } else {
                fallback(content)
            }
        } else {
            fallback(content)
        }
    }

    private var tintColor: Color {
        tint ?? GlassTokens(t, scheme: scheme).floatingTint
    }

    /// No shadow on the disc: a shadow renders its view offscreen, where the material has nothing behind it to blur (see `GlassPlaneBackground`). The rim carries the edge.
    private func fallback(_ content: Content) -> some View {
        let glass = GlassTokens(t, scheme: scheme)
        return content.background {
            ZStack {
                shape.fill(.regularMaterial)
                shape.fill(tint ?? glass.chromeTint)
            }
            .overlay { shape.stroke(glass.rim, lineWidth: 1 / displayScale) }
        }
    }
}

/// Floating controls that sit together: on iOS 26 their glass shares one `GlassEffectContainer`, so neighbours are rendered in one pass against one backdrop rather than each sampling the others; below 26 the group is a plain row.
/// The container's blend distance is half the row's spacing, so neighbours stay separate discs and never melt into one shape.
struct GlassControlRow<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(iOS 26.0, *) {
            if GlassRendering.current == .liquidGlass {
                GlassEffectContainer(spacing: spacing / 2) {
                    HStack(spacing: spacing, content: content)
                }
            } else {
                HStack(spacing: spacing, content: content)
            }
        } else {
            HStack(spacing: spacing, content: content)
        }
    }
}
