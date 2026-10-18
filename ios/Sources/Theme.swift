import SwiftUI

// Design language borrowed from Rift/Soar: true-black atmospheric canvas,
// white type in three levels, a glossy azure primary button, Liquid Glass
// controls on iOS 26 (material fallback before), and a 24/20/14 radius ladder.

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

enum ES {
    // Canvas + surfaces
    static let canvas = Color.black
    static let surface = Color(hex: 0x0D0D0D)
    static let raised = Color(hex: 0x141821)
    static let hairline = Color.white.opacity(0.10)
    static let hairlineStrong = Color.white.opacity(0.16)

    // Text: three levels only
    static let text = Color.white
    static let text2 = Color.white.opacity(0.72)
    static let text3 = Color.white.opacity(0.46)

    // Accent
    static let accent = Color(hex: 0x7FA4FF)
    static let gradTop = Color(hex: 0x1A2F9E)
    static let gradBottom = Color(hex: 0x2F68FF)
    static let rim = Color(hex: 0x7FA4FF)
    static let green = Color(hex: 0x78E6A0)
    static let amber = Color(hex: 0xFFB066)
    static let pink = Color(hex: 0xFF8AA0)

    // Radii
    static let frame: CGFloat = 24
    static let nested: CGFloat = 20
    static let control: CGFloat = 14

    static func display(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
}

// MARK: - Atmosphere

/// Night-sky canvas: black, a faint blue bloom at the top and a slow field of
/// stars. Static stars (seeded) so it never shimmers on redraw.
struct Atmosphere: View {
    var body: some View {
        ZStack {
            ES.canvas
            RadialGradient(colors: [ES.gradBottom.opacity(0.22), .clear],
                           center: .init(x: 0.5, y: -0.05), startRadius: 0, endRadius: 520)
            Canvas { ctx, size in
                var rng = SeededRNG(seed: 7)
                for _ in 0..<90 {
                    let x = Double.random(in: 0...1, using: &rng) * size.width
                    let y = Double.random(in: 0...0.62, using: &rng) * size.height
                    let r = Double.random(in: 0.4...1.3, using: &rng)
                    let a = Double.random(in: 0.15...0.7, using: &rng)
                    ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)), with: .color(.white.opacity(a)))
                }
            }
        }
        .ignoresSafeArea()
    }
}

struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func next() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
}

// MARK: - Glass

extension View {
    /// Rounded glass surface: native Liquid Glass on iOS 26, material before.
    @ViewBuilder
    func glassCard(radius: CGFloat = ES.frame) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: radius))
        } else {
            self.background(.ultraThinMaterial, in: .rect(cornerRadius: radius))
                .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(ES.hairlineStrong))
        }
    }

    @ViewBuilder
    func glassPill(interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(interactive ? .clear.interactive() : .clear, in: .capsule)
        } else {
            self.background(.ultraThinMaterial, in: .capsule)
                .overlay(Capsule().strokeBorder(ES.hairline))
        }
    }

    /// Quiet opaque content card (rows, lists) — glass is for controls only.
    func contentCard(radius: CGFloat = ES.nested) -> some View {
        background(ES.surface, in: .rect(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(ES.hairline))
    }
}

// MARK: - Buttons

/// The glossy azure primary button.
struct GlossyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(
                Capsule().fill(LinearGradient(colors: [ES.gradTop, ES.gradBottom], startPoint: .top, endPoint: .bottom))
            )
            .overlay(Capsule().strokeBorder(LinearGradient(colors: [ES.rim.opacity(0.9), ES.rim.opacity(0.1)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .shadow(color: ES.gradBottom.opacity(configuration.isPressed ? 0.2 : 0.45), radius: 18, y: 6)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(duration: 0.25), value: configuration.isPressed)
    }
}

/// Secondary: dark pill with a hairline (Rift's "Download iOS App" buttons).
struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(ES.text)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Capsule().fill(Color(hex: 0x141414)))
            .overlay(Capsule().strokeBorder(ES.hairline))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

// MARK: - Bits

struct Eyebrow: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(ES.text3)
    }
}

struct StatusDot: View {
    let label: String
    let color: Color
    var pulsing = false
    @State private var on = false
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 7, height: 7)
                .shadow(color: color.opacity(0.8), radius: on ? 5 : 1)
                .opacity(pulsing && on ? 0.55 : 1)
            Text(label).font(.system(size: 13, weight: .medium)).foregroundStyle(ES.text2)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .glassPill()
        .onAppear {
            guard pulsing else { return }
            withAnimation(.easeInOut(duration: 1).repeatForever()) { on = true }
        }
    }
}

/// Monogram avatar on a stable gradient seeded by the name.
struct Monogram: View {
    let name: String
    var size: CGFloat = 44
    private var colors: [Color] {
        let palettes: [[UInt32]] = [[0x2F68FF, 0x1A2F9E], [0x7FA4FF, 0x5069F2], [0xFF8AA0, 0xA855F7],
                                    [0x78E6A0, 0x0AA15A], [0xFFB066, 0xCF4444], [0xA3B3F8, 0x6366F1]]
        // 32-bit wrapping hash, identical to palFor() on the website.
        let h = name.unicodeScalars.reduce(Int32(0)) { $0 &* 31 &+ Int32(truncatingIfNeeded: $1.value) }
        let i = Int(h.magnitude % UInt32(palettes.count))
        return palettes[i].map { Color(hex: $0) }
    }
    var body: some View {
        let initials = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
        Text(initials.isEmpty ? "?" : initials.uppercased())
            .font(.system(size: size * 0.38, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)))
            .overlay(Circle().strokeBorder(.white.opacity(0.18)))
    }
}

/// Dot-matrix sound field: a grid of dots whose rows swell with the live mic
/// level — the audio counterpart of Rift's dot-matrix globe.
struct SoundField: View {
    let level: Float
    let active: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !active)) { t in
            Canvas { ctx, size in
                let cols = 34, rows = 9
                let dx = size.width / CGFloat(cols), dy = size.height / CGFloat(rows)
                let time = t.date.timeIntervalSinceReferenceDate
                let amp = active ? min(1, Double(sqrt(max(level, 0))) * 4) : 0
                for c in 0..<cols {
                    let x = (CGFloat(c) + 0.5) * dx
                    let env = sin(Double(c) / Double(cols - 1) * .pi)
                    let wave = (sin(Double(c) * 0.55 + time * 3.2) * 0.5 + 0.5) * env
                    let reach = (0.12 + 0.88 * amp * wave) * Double(rows) / 2
                    for r in 0..<rows {
                        let y = (CGFloat(r) + 0.5) * dy
                        let fromMid = abs(Double(r) - Double(rows - 1) / 2)
                        let lit = fromMid <= reach
                        let a = lit ? 0.95 - fromMid / Double(rows) : 0.10
                        let d: CGFloat = lit ? 3.2 : 2.2
                        ctx.fill(Path(ellipseIn: CGRect(x: x - d / 2, y: y - d / 2, width: d, height: d)),
                                 with: .color((lit ? ES.accent : .white).opacity(a)))
                    }
                }
            }
        }
    }
}
