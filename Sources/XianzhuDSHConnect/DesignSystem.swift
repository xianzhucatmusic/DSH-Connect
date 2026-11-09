//
//  DesignSystem.swift — 全局视觉规范：颜色、圆角、阴影、按钮样式、动效。
//
//  设计基调：浅色、幼态萌、动画轻微克制、系统苹方。
//  配色沿用 App 图标（天蓝喵 + 樱花粉），保证图标与界面是一套。
//
//  所有页面都从这里取样式，想整体换肤只改这一个文件。
//

import SwiftUI

// MARK: - 配色

/// 自适应颜色：浅色/深色两套，跟随系统或 App 设置。
private func adaptive(light: NSColor, dark: NSColor) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark ? dark : light
    })
}

private func rgb(_ r: Double, _ g: Double, _ b: Double) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
}

enum Palette {
    /// 主色：天蓝。按钮、选中态、进度条。
    static let sky = adaptive(light: rgb(0.31, 0.76, 0.97), dark: rgb(0.42, 0.80, 1.00))
    static let skyDeep = adaptive(light: rgb(0.17, 0.64, 0.90), dark: rgb(0.55, 0.85, 1.00))
    static let skySoft = adaptive(light: rgb(0.88, 0.96, 1.00), dark: rgb(0.12, 0.22, 0.31))

    /// 辅色：樱花粉。强调、高亮、重要标记。
    static let sakura = adaptive(light: rgb(1.00, 0.71, 0.76), dark: rgb(1.00, 0.62, 0.70))
    static let sakuraDeep = adaptive(light: rgb(1.00, 0.55, 0.64), dark: rgb(1.00, 0.70, 0.77))
    static let sakuraSoft = adaptive(light: rgb(1.00, 0.94, 0.95), dark: rgb(0.27, 0.19, 0.23))

    /// 奶油底。
    static let cream = adaptive(light: rgb(0.99, 0.98, 0.97), dark: rgb(0.11, 0.12, 0.15))
    static let card = adaptive(light: rgb(1, 1, 1), dark: rgb(0.16, 0.18, 0.22))
    static let cardHover = adaptive(light: rgb(0.99, 0.99, 1.00), dark: rgb(0.19, 0.21, 0.26))

    /// 文字。
    static let ink = adaptive(light: rgb(0.18, 0.22, 0.28), dark: rgb(0.92, 0.93, 0.95))
    static let inkSoft = adaptive(light: rgb(0.44, 0.50, 0.59), dark: rgb(0.66, 0.70, 0.76))
    static let inkFaint = adaptive(light: rgb(0.68, 0.72, 0.77), dark: rgb(0.45, 0.49, 0.55))

    /// 语义色。
    static let mint = adaptive(light: rgb(0.41, 0.83, 0.57), dark: rgb(0.47, 0.88, 0.62))
    static let amber = adaptive(light: rgb(0.96, 0.68, 0.33), dark: rgb(0.98, 0.75, 0.44))
    static let coral = adaptive(light: rgb(0.99, 0.51, 0.51), dark: rgb(1.00, 0.60, 0.60))

    /// 描边与分隔。
    static let hairline = adaptive(light: rgb(0.93, 0.94, 0.96), dark: rgb(0.23, 0.25, 0.30))
    static let ring = adaptive(light: rgb(0.86, 0.90, 0.94), dark: rgb(0.30, 0.33, 0.39))

    /// 粉蓝渐变（主按钮、进度条）。
    static var candyGradient: LinearGradient {
        LinearGradient(
            colors: [sky, sakura],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - 尺寸与圆角

enum Shape_ {
    static let cardRadius: CGFloat = 16
    static let buttonRadius: CGFloat = 10
    static let fieldRadius: CGFloat = 10
    static let bubbleRadius: CGFloat = 16
    static let gutter: CGFloat = 14
}

// MARK: - 阴影

extension View {
    /// 卡片阴影：柔和、带一点蓝调，避免死黑。
    func softShadow(_ level: SoftShadow = .rest) -> some View {
        modifier(SoftShadowModifier(level: level))
    }

    /// 卡片外观：白底 + 圆角 + 描边 + 阴影。
    func cardSurface(hovering: Bool = false) -> some View {
        self
            .background(hovering ? Palette.cardHover : Palette.card)
            .clipShape(RoundedRectangle(cornerRadius: Shape_.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Shape_.cardRadius, style: .continuous)
                    .stroke(Palette.hairline, lineWidth: 1)
            )
            .softShadow(hovering ? .lifted : .rest)
    }
}

enum SoftShadow {
    case rest, lifted, floating
}

struct SoftShadowModifier: ViewModifier {
    let level: SoftShadow

    func body(content: Content) -> some View {
        switch level {
        case .rest:
            content.shadow(color: Palette.sky.opacity(0.10), radius: 6, x: 0, y: 2)
        case .lifted:
            content.shadow(color: Palette.sky.opacity(0.18), radius: 12, x: 0, y: 5)
        case .floating:
            content.shadow(color: Palette.sakura.opacity(0.22), radius: 16, x: 0, y: 6)
        }
    }
}

// MARK: - 按钮样式

/// 主按钮：粉蓝渐变胶囊。
struct CandyButtonStyle: ButtonStyle {
    var compact = false
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 11.5 : 12.5, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 12 : 16)
            .padding(.vertical, compact ? 6 : 9)
            .background(Palette.candyGradient)
            .clipShape(Capsule())
            .shadow(color: Palette.sakura.opacity(hovering ? 0.35 : 0.20),
                    radius: hovering ? 8 : 4, x: 0, y: 2)
            .scaleEffect(configuration.isPressed ? 0.96 : (hovering ? 1.02 : 1.0))
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .onHover { hovering = $0 }
    }
}

/// 次要按钮：白底、蓝描边。
struct SoftButtonStyle: ButtonStyle {
    var compact = false
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 11 : 12, weight: .regular))
            .foregroundStyle(hovering ? Palette.skyDeep : Palette.inkSoft)
            .padding(.horizontal, compact ? 10 : 14)
            .padding(.vertical, compact ? 5 : 7)
            .background(hovering ? Palette.skySoft : Palette.card)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(hovering ? Palette.sky.opacity(0.5) : Palette.hairline,
                                      lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.72), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.13), value: hovering)
            .onHover { hovering = $0 }
    }
}

/// 图标按钮：圆形、悬停变色。
struct RoundIconStyle: ButtonStyle {
    var tint: Color = Palette.sky
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(hovering ? .white : tint)
            .frame(width: 26, height: 26)
            .background(hovering ? tint : tint.opacity(0.12))
            .clipShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.9 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
    }
}

// MARK: - 胶囊标签

struct CapsuleTag: View {
    let text: String
    var tint: Color = Palette.sky

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.opacity(0.14))
            .clipShape(Capsule())
    }
}

// MARK: - 状态点

struct StatusDot: View {
    let color: Color
    var pulsing = false
    @State private var phase: CGFloat = 0

    var body: some View {
        ZStack {
            if pulsing {
                Circle()
                    .fill(color.opacity(0.28))
                    .frame(width: 14, height: 14)
                    .scaleEffect(1 + phase * 0.7)
                    .opacity(1 - phase)
            }
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
        }
        .frame(width: 14, height: 14)
        .onAppear {
            guard pulsing else { return }
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
    }
}

// MARK: - 跳动打字指示

struct TypingDots: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(Palette.sky.opacity(0.65))
                    .frame(width: 6, height: 6)
                    .offset(y: animating ? -3 : 3)
                    .animation(
                        .easeInOut(duration: 0.5)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.13),
                        value: animating
                    )
            }
        }
        .onAppear { animating = true }
    }
}

// MARK: - 分区标题

struct SectionHeader: View {
    let icon: String
    let title: String
    var tint: Color = Palette.sky

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 18, height: 18)
                .background(tint.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.ink)
            Spacer()
        }
    }
}

// MARK: - 空状态

struct CuteEmptyState: View {
    let icon: String
    let title: String
    var hint: String? = nil
    var tint: Color = Palette.sky

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(tint.opacity(0.45))
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Palette.inkSoft)
            if let hint {
                Text(hint)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.inkFaint)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }
}

// MARK: - 输入框外观

extension View {
    /// 圆角输入框外观：白底、细描边、聚焦时蓝色光晕。
    func cuteField(focused: Bool = false) -> some View {
        self
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Palette.card)
            .clipShape(RoundedRectangle(cornerRadius: Shape_.fieldRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Shape_.fieldRadius, style: .continuous)
                    .stroke(focused ? Palette.sky : Palette.hairline,
                            lineWidth: focused ? 1.5 : 1)
            )
            .shadow(color: Palette.sky.opacity(focused ? 0.16 : 0), radius: focused ? 6 : 0)
            .animation(.easeOut(duration: 0.16), value: focused)
    }
}
