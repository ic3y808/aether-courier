import SwiftUI

/// Modern "aurora glass" backdrop: a deep indigo base washed with soft, blurred
/// gradient blooms (violet, magenta, electric blue) that read as coloured light
/// behind the app's frosted-glass panels — an iOS-Liquid-Glass feel that's fancy,
/// human, and premium. `intensity` scales how vivid the blooms are per pane so
/// busier surfaces stay legible.
struct AuroraBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    var intensity: Double = 1.0

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let s = max(w, h)
            ZStack {
                base
                bloom(Palette.violet,  at: CGPoint(x: w * 0.12, y: h * -0.02), r: s * 0.62)
                bloom(Palette.magenta, at: CGPoint(x: w * 1.02, y: h * 0.18),  r: s * 0.55)
                bloom(Palette.blue,    at: CGPoint(x: w * 0.55, y: h * 1.06),  r: s * 0.7)
                bloom(Palette.indigo,  at: CGPoint(x: w * -0.08, y: h * 0.82), r: s * 0.5)
                grain.opacity(0.5 * intensity)
                vignette
            }
            .compositingGroup()
        }
        .ignoresSafeArea()
    }

    private var base: some View {
        LinearGradient(
            colors: scheme == .dark
                ? [Color(red: 0.058, green: 0.050, blue: 0.104), Color(red: 0.030, green: 0.026, blue: 0.060)]
                : [Color(red: 0.960, green: 0.962, blue: 0.992), Color(red: 0.906, green: 0.918, blue: 0.980)],
            startPoint: .top, endPoint: .bottom)
    }

    private func bloom(_ color: Color, at p: CGPoint, r: CGFloat) -> some View {
        RadialGradient(
            colors: [color.opacity((scheme == .dark ? 0.42 : 0.26) * intensity), .clear],
            center: .center, startRadius: 0, endRadius: r)
        .frame(width: r * 2, height: r * 2)
        .position(p)
        .blur(radius: 34)
    }

    /// Faint film grain so the smooth gradients don't band on wide displays.
    private var grain: some View {
        Canvas { ctx, size in
            var seed: UInt64 = 0x9E3779B97F4A7C15
            func rnd() -> CGFloat {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return CGFloat((seed >> 33) & 0xFFFF) / 65535.0
            }
            let dots = min(3800, Int((size.width * size.height) / 300))
            let tint = scheme == .dark ? Color.white : Color.black
            for _ in 0..<dots {
                let d = 0.6 + rnd() * 0.8
                let a = (scheme == .dark ? 0.018 : 0.02) + rnd() * 0.03
                ctx.fill(Path(ellipseIn: CGRect(x: rnd() * size.width, y: rnd() * size.height, width: d, height: d)),
                         with: .color(tint.opacity(a)))
            }
        }
    }

    private var vignette: some View {
        RadialGradient(
            colors: [.clear, Color.black.opacity(scheme == .dark ? 0.34 : 0.07)],
            center: .center, startRadius: 220, endRadius: 940)
    }

    enum Palette {
        static let violet  = Color(red: 0.49, green: 0.24, blue: 0.93)
        static let magenta = Color(red: 0.92, green: 0.28, blue: 0.60)
        static let blue    = Color(red: 0.24, green: 0.44, blue: 0.96)
        static let indigo  = Color(red: 0.36, green: 0.31, blue: 0.86)
    }
}

extension LinearGradient {
    /// The app's signature accent — violet → magenta — for primary actions,
    /// selection, and glass highlights.
    static let aetherAccent = LinearGradient(
        colors: [Color(red: 0.55, green: 0.36, blue: 0.97), Color(red: 0.93, green: 0.33, blue: 0.63)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
}

extension Color {
    /// Solid form of the signature accent, for tint / single-color contexts.
    static let aetherAccent = Color(red: 0.60, green: 0.38, blue: 0.96)
}

/// A reusable frosted-glass surface: translucent material + a soft top-edge
/// highlight and hairline border, for the app's Liquid-Glass panels and cards.
struct GlassCard: ViewModifier {
    var corner: CGFloat = 14
    var strokeOpacity: Double = 0.14
    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [.white.opacity(strokeOpacity * 2), .white.opacity(strokeOpacity * 0.3)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 0.75)
            )
    }
}

extension View {
    func glassCard(corner: CGFloat = 14, strokeOpacity: Double = 0.14) -> some View {
        modifier(GlassCard(corner: corner, strokeOpacity: strokeOpacity))
    }
}

/// A soft, slowly-breathing gradient orb with an optional glyph — the app's
/// signature decorative flourish for empty states, headers, and greetings.
struct GlowOrb: View {
    var systemImage: String? = nil
    var size: CGFloat = 104

    var body: some View {
        ZStack {
            // outer glow (static — animating its size reflowed parents)
            Circle()
                .fill(LinearGradient.aetherAccent)
                .frame(width: size, height: size)
                .blur(radius: size * 0.3)
                .opacity(0.5)
            // solid disc
            Circle()
                .fill(LinearGradient.aetherAccent)
                .frame(width: size * 0.8, height: size * 0.8)
                .overlay(
                    Circle().fill(
                        LinearGradient(colors: [.white.opacity(0.30), .clear],
                                       startPoint: .topLeading, endPoint: .center))
                )
                .overlay(Circle().strokeBorder(.white.opacity(0.22), lineWidth: 1))
                .shadow(color: Color.aetherAccent.opacity(0.55), radius: 20, y: 8)
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.34, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
            }
        }
        // Pin the LAYOUT size so the blurred glow renders beyond these bounds
        // without changing the measured size (which reflowed parents).
        .frame(width: size, height: size)
    }
}

/// A scatter of static sparkles for a touch of flair. Purely decorative,
/// fixed-size, no animation (kept layout-inert).
struct Sparkles: View {
    var count: Int = 5
    var body: some View {
        Canvas { ctx, size in
            var seed: UInt64 = 0xD1B54A32D192ED03
            func rnd() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1; return CGFloat((seed >> 33) & 0xFFFF)/65535 }
            for _ in 0..<count {
                let x = rnd() * size.width, y = rnd() * size.height
                let r = 1.5 + rnd() * 2.5
                let a = 0.18 + rnd() * 0.28
                ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r*2, height: r*2)),
                         with: .color(.white.opacity(a)))
            }
        }
        .allowsHitTesting(false)
    }
}

/// A premium, on-brand empty state: a glowing orb, a title, and a message.
struct FancyEmptyState: View {
    let title: String
    let message: String
    var systemImage: String = "envelope.open"
    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Sparkles(count: 7).frame(width: 200, height: 160)
                GlowOrb(systemImage: systemImage)
            }
            Text(title).font(.title2).fontWeight(.semibold)
            Text(message)
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
