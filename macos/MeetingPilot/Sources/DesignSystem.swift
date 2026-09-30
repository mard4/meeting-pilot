import AppKit
import CoreText
import SwiftUI

extension Color {
    /// White-ish in dark mode, black-ish in light mode, at the same opacity. Backed by a
    /// dynamic `NSColor` so it follows the in-app `.preferredColorScheme()` override.
    /// Keep `.white` for text sitting on a fixed saturated fill (e.g. the crimson button).
    static func adaptiveWhite(_ opacity: Double = 1.0) -> Color {
        Color(
            NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return (isDark ? NSColor.white : NSColor.black).withAlphaComponent(opacity)
            }
        )
    }

    static func dynamic(light: UInt32, dark: UInt32, lightAlpha: Double = 1, darkAlpha: Double = 1) -> Color {
        Color(
            NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return NSColor(hex: isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
            }
        )
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: Double = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

/// Visual tokens shared with the marketing site (site/src/style.css): near-black
/// canvas, crimson accent, Unbounded display type, spring motion. Every token is a
/// dynamic color so light and dark mode can't drift apart view by view.
enum MeetingPilotDesign {
    static let accent = Color.dynamic(light: 0xC81E33, dark: 0xE0283F)
    static let accentStrong = Color.dynamic(light: 0xB0182C, dark: 0xEF2F49)
    static let accentTint = Color.dynamic(light: 0xC81E33, dark: 0xE0283F, lightAlpha: 0.08, darkAlpha: 0.14)
    static let success = Color.dynamic(light: 0x1F9D63, dark: 0x3ECF8E)
    static let warning = Color.dynamic(light: 0xB86E00, dark: 0xF5A524)

    static let canvasColor = Color.dynamic(light: 0xF6F5F7, dark: 0x0A0A0C)
    static let sidebarColor = Color.dynamic(light: 0xEEEDF0, dark: 0x111114)
    static let surfaceColor = Color.dynamic(light: 0xFFFFFF, dark: 0x131316)
    static let elevatedColor = Color.dynamic(light: 0xFFFFFF, dark: 0x1A1A1F)
    static let fieldColor = Color.dynamic(light: 0xFFFFFF, dark: 0x0E0E11)
    static let hoverColor = Color.dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.045, darkAlpha: 0.06)
    static let lineColor = Color.dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.09, darkAlpha: 0.08)
    static let lineStrongColor = Color.dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.16, darkAlpha: 0.16)

    static let textColor = Color.dynamic(light: 0x111114, dark: 0xF4F4F6)
    static let textDimColor = Color.dynamic(light: 0x55555F, dark: 0xA3A3AC)
    static let textFaintColor = Color.dynamic(light: 0x8A8A94, dark: 0x6D6D78)

    static let cornerRadius = MPRadius.card
    static let controlRadius = MPRadius.control
    static let sidebarWidth: CGFloat = 212

    static func canvas(for scheme: ColorScheme) -> Color { canvasColor }
    static func sidebar(for scheme: ColorScheme) -> Color { sidebarColor }
    static func surface(for scheme: ColorScheme) -> Color { surfaceColor }
    static func border(for scheme: ColorScheme) -> Color { lineColor }
    static func primaryText(for scheme: ColorScheme) -> Color { textColor }
    static func secondaryText(for scheme: ColorScheme) -> Color { textDimColor }
    static func tertiaryText(for scheme: ColorScheme) -> Color { textFaintColor }
}

// MARK: - Radii

/// Continuous-corner radii, largest container to smallest. Nested shapes step down one
/// level so inner corners stay concentric with their parent.
enum MPRadius {
    /// Floating chrome that sits directly on the window (sidebar glass).
    static let window: CGFloat = 18
    /// Cards and page-level panels.
    static let card: CGFloat = 16
    /// Panels and list groups nested inside a card.
    static let panel: CGFloat = 12
    /// Buttons, fields, selectable rows, inline banners.
    static let control: CGFloat = 10
    /// Icon tiles, tags, thumbnails.
    static let chip: CGFloat = 6
}

// MARK: - Typography

/// SF Pro type scale for everything that isn't a display title (`Font.mpDisplay`) or an
/// eyebrow (`Font.mpEyebrow`). Pick the step, vary only weight and design.
enum MPFont {
    /// Empty-state and hero glyphs.
    static func hero(_ weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: 22, weight: weight, design: design)
    }
    /// In-content headings (rendered markdown H2, dialog titles).
    static func title(_ weight: Font.Weight = .semibold, design: Font.Design = .default) -> Font {
        .system(size: 16, weight: weight, design: design)
    }
    /// Section titles.
    static func headline(_ weight: Font.Weight = .semibold, design: Font.Design = .default) -> Font {
        .system(size: 15, weight: weight, design: design)
    }
    /// Emphasised row titles and sidebar/toolbar glyphs.
    static func subheadline(_ weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: 14, weight: weight, design: design)
    }
    /// Default reading size for content and controls.
    static func body(_ weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: 13, weight: weight, design: design)
    }
    /// Secondary lines under a title, compact controls.
    static func callout(_ weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: 12, weight: weight, design: design)
    }
    /// Metadata, hints, timestamps.
    static func caption(_ weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: 11, weight: weight, design: design)
    }
    /// Dense metadata and badges.
    static func footnote(_ weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: 10, weight: weight, design: design)
    }
    /// Glyphs inside badges and step indicators; never for sentences.
    static func micro(_ weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: 9, weight: weight, design: design)
    }
}

enum MeetingPilotFonts {
    static let displayFamily = "Unbounded"

    static func register() {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Fonts/Unbounded-Variable.ttf"),
              FileManager.default.fileExists(atPath: url.path),
              NSFont(name: displayFamily, size: 12) == nil
        else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
}

extension Font {
    /// Brand display face for page titles and hero numbers only — body text and controls
    /// stay SF Pro, which reads better at small sizes and matches native macOS chrome.
    static func mpDisplay(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        if NSFont(name: MeetingPilotFonts.displayFamily, size: size) != nil {
            return .custom(MeetingPilotFonts.displayFamily, size: size).weight(weight)
        }
        return .system(size: size, weight: weight, design: .rounded)
    }

    static func mpEyebrow(_ size: CGFloat = 10) -> Font {
        .system(size: size, weight: .medium, design: .monospaced)
    }
}

// MARK: - Motion

extension Animation {
    /// Critically damped: state changes that should settle without overshoot.
    static let mpSmooth = Animation.spring(response: 0.42, dampingFraction: 1)
    /// Slight overshoot for direct manipulation (press, toggle, selection).
    static let mpSnappy = Animation.spring(response: 0.28, dampingFraction: 0.82)
}

// MARK: - Brand mark

/// The headphone + waveform mark from design/app_icon_white.svg (512 viewBox), drawn
/// natively so it stays crisp at every size and can recolor for light mode and the
/// template menu bar image.
enum BrandMarkGeometry {
    private static let contentBox = CGRect(x: 38, y: 93, width: 436, height: 404)

    static func paths(fitting rect: CGRect) -> (neutral: CGPath, accent: CGPath) {
        let scale = min(rect.width / contentBox.width, rect.height / contentBox.height)
        let offsetX = rect.minX + (rect.width - contentBox.width * scale) / 2 - contentBox.minX * scale
        let offsetY = rect.minY + (rect.height - contentBox.height * scale) / 2 - contentBox.minY * scale
        var transform = CGAffineTransform(translationX: offsetX, y: offsetY).scaledBy(x: scale, y: scale)

        let band = CGMutablePath()
        band.move(to: CGPoint(x: 110, y: 262))
        band.addCurve(to: CGPoint(x: 402, y: 262), control1: CGPoint(x: 110, y: 68), control2: CGPoint(x: 402, y: 68))
        let neutral = CGMutablePath()
        neutral.addPath(band.copy(strokingWithWidth: 46, lineCap: .round, lineJoin: .round, miterLimit: 10))
        neutral.addEllipse(in: CGRect(x: 38, y: 250, width: 144, height: 144))
        neutral.addEllipse(in: CGRect(x: 330, y: 250, width: 144, height: 144))
        neutral.addRoundedRect(in: CGRect(x: 187, y: 227, width: 38, height: 190), cornerWidth: 19, cornerHeight: 19)
        neutral.addRoundedRect(in: CGRect(x: 287, y: 227, width: 38, height: 190), cornerWidth: 19, cornerHeight: 19)

        let accent = CGMutablePath()
        accent.addRoundedRect(in: CGRect(x: 237, y: 147, width: 38, height: 350), cornerWidth: 19, cornerHeight: 19)

        return (
            neutral.copy(using: &transform) ?? neutral,
            accent.copy(using: &transform) ?? accent
        )
    }

    /// Monochrome template image for the menu bar: AppKit tints it for light/dark
    /// menu bars and the highlighted state automatically.
    static func templateImage(pointSize: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let parts = paths(fitting: rect.insetBy(dx: 0.5, dy: 1))
            context.setFillColor(NSColor.black.cgColor)
            context.addPath(parts.neutral)
            context.addPath(parts.accent)
            context.fillPath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Meeting Pilot"
        return image
    }
}

struct BrandMark: View {
    var size: CGFloat = 22
    var neutral: Color = MeetingPilotDesign.textColor
    var accent: Color = MeetingPilotDesign.accent

    var body: some View {
        Canvas { context, canvasSize in
            let parts = BrandMarkGeometry.paths(fitting: CGRect(origin: .zero, size: canvasSize))
            context.fill(Path(parts.neutral), with: .color(neutral))
            context.fill(Path(parts.accent), with: .color(accent))
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Meeting Pilot")
    }
}

/// The app's liquid-metal logo tile (assets/app_logo_liquid.png, rendered from the
/// site's hero shader), for places that represent the app itself.
struct BrandTile: View {
    var size: CGFloat = 32

    private static let image: NSImage? = Bundle.main.resourceURL
        .flatMap { NSImage(contentsOf: $0.appendingPathComponent("app_logo_liquid.png")) }

    var body: some View {
        Group {
            if let image = Self.image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                        .fill(Color(nsColor: NSColor(hex: 0x120A0C)))
                    BrandMark(size: size * 0.7, neutral: Color(nsColor: NSColor(hex: 0xF4F4F6)), accent: Color(nsColor: NSColor(hex: 0xEF2F49)))
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Meeting Pilot")
    }
}

// MARK: - Surfaces

extension View {
    /// Panel surface from the site: flat fill, hairline border, continuous corners.
    func mpCard(padding: CGFloat = 16, radius: CGFloat = MPRadius.card, elevated: Bool = false) -> some View {
        self
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(elevated ? MeetingPilotDesign.elevatedColor : MeetingPilotDesign.surfaceColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(MeetingPilotDesign.lineColor, lineWidth: 1)
            )
    }

    /// Liquid Glass on macOS 26+, material fallback before that.
    @ViewBuilder
    func meetingPilotGlass<S: Shape>(
        in shape: S,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        if #available(macOS 26.0, *) {
            if let tint {
                self.glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
            } else {
                self.glassEffect(.regular.interactive(interactive), in: shape)
            }
        } else {
            self
                .background(.regularMaterial, in: shape)
                .overlay(shape.stroke(Color.primary.opacity(0.10), lineWidth: 1))
        }
    }
}

/// Canvas behind every window: the site's near-black with a faint crimson glow in the
/// top corner so glass surfaces have tonal variation to sample.
struct MeetingPilotBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            MeetingPilotDesign.canvasColor
            RadialGradient(
                colors: [MeetingPilotDesign.accent.opacity(colorScheme == .dark ? 0.16 : 0.06), .clear],
                center: UnitPoint(x: 0.12, y: -0.05),
                startRadius: 0,
                endRadius: 560
            )
            RadialGradient(
                colors: [Color(nsColor: NSColor(hex: 0x7A2B5C)).opacity(colorScheme == .dark ? 0.10 : 0.0), .clear],
                center: UnitPoint(x: 1.0, y: 1.05),
                startRadius: 0,
                endRadius: 520
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - Text

struct MPEyebrow: View {
    let text: String
    var color: Color = MeetingPilotDesign.textFaintColor

    init(_ text: String, color: Color = MeetingPilotDesign.textFaintColor) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(localized(text).uppercased())
            .font(.mpEyebrow())
            .tracking(1.2)
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

struct MPPageHeader<Trailing: View>: View {
    let title: String
    var eyebrow: String? = nil
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                if let eyebrow { MPEyebrow(eyebrow) }
                Text(localized(title))
                    .font(.mpDisplay(24))
                    .foregroundStyle(MeetingPilotDesign.textColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let subtitle, !subtitle.isEmpty {
                    Text(localized(subtitle))
                        .font(MPFont.body())
                        .foregroundStyle(MeetingPilotDesign.textDimColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
    }
}

extension MPPageHeader where Trailing == EmptyView {
    init(title: String, eyebrow: String? = nil, subtitle: String? = nil) {
        self.init(title: title, eyebrow: eyebrow, subtitle: subtitle) { EmptyView() }
    }
}

struct MPSectionTitle: View {
    let title: String
    var detail: String? = nil

    init(_ title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(localized(title))
                .font(MPFont.headline())
                .foregroundStyle(MeetingPilotDesign.textColor)
            if let detail, !detail.isEmpty {
                Text(localized(detail))
                    .font(MPFont.callout())
                    .foregroundStyle(MeetingPilotDesign.textFaintColor)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Badges & callouts

enum MPTone {
    case accent, success, warning, neutral

    var color: Color {
        switch self {
        case .accent: return MeetingPilotDesign.accent
        case .success: return MeetingPilotDesign.success
        case .warning: return MeetingPilotDesign.warning
        case .neutral: return MeetingPilotDesign.textDimColor
        }
    }
}

struct MPBadge: View {
    let text: String
    var tone: MPTone = .neutral
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(MPFont.micro(.bold))
            } else if tone != .neutral {
                Circle().frame(width: 6, height: 6)
            }
            Text(localized(text))
                .font(MPFont.caption(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(tone.color)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(tone.color.opacity(tone == .neutral ? 0.10 : 0.13)))
        .fixedSize()
    }
}

struct MPCallout<Actions: View>: View {
    var tone: MPTone = .warning
    let systemImage: String
    let title: String
    let message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: systemImage)
                .font(MPFont.headline())
                .foregroundStyle(tone.color)
                .frame(width: 34, height: 34)
                .background(Circle().fill(tone.color.opacity(0.14)))
            VStack(alignment: .leading, spacing: 3) {
                Text(localized(title))
                    .font(MPFont.body(.semibold))
                    .foregroundStyle(MeetingPilotDesign.textColor)
                Text(localized(message))
                    .font(MPFont.callout())
                    .foregroundStyle(MeetingPilotDesign.textDimColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(3)
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) { actions }
                .fixedSize()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: MPRadius.card, style: .continuous)
                .fill(tone.color.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: MPRadius.card, style: .continuous)
                .strokeBorder(tone.color.opacity(0.28), lineWidth: 1)
        )
    }
}

// MARK: - Buttons

/// Crimson pill echoing the site's liquid-metal CTA: vertical metal gradient plus a
/// bright top rim, pressed state sinks with a spring.
struct MPPrimaryButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        MPPrimaryButtonBody(configuration: configuration, compact: compact)
    }
}

private struct MPPrimaryButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let compact: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(compact ? MPFont.callout(.semibold) : MPFont.body(.semibold))
            .foregroundStyle(.white)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, compact ? 11 : 15)
            .frame(minHeight: compact ? 26 : 32)
            .background(
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(nsColor: NSColor(hex: 0xF0485D)),
                                Color(nsColor: NSColor(hex: 0xD4243C)),
                                Color(nsColor: NSColor(hex: 0x9E1528)),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom),
                        lineWidth: 1
                    )
            )
            .shadow(color: Color(nsColor: NSColor(hex: 0xD4243C)).opacity(hovering && isEnabled ? 0.45 : 0.22), radius: hovering ? 10 : 6, y: 2)
            .brightness(configuration.isPressed ? -0.08 : (hovering ? 0.04 : 0))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(.mpSnappy, value: configuration.isPressed)
            .animation(.mpSmooth, value: hovering)
            .onHover { hovering = $0 }
            .contentShape(Capsule())
    }
}

struct MPSecondaryButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        MPSecondaryButtonBody(configuration: configuration, compact: compact)
    }
}

private struct MPSecondaryButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let compact: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(compact ? MPFont.callout(.medium) : MPFont.body(.medium))
            .foregroundStyle(MeetingPilotDesign.textColor)
            .padding(.horizontal, compact ? 10 : 14)
            .frame(minHeight: compact ? 26 : 32)
            .background(Capsule().fill(hovering ? MeetingPilotDesign.hoverColor : MeetingPilotDesign.elevatedColor))
            .overlay(Capsule().strokeBorder(MeetingPilotDesign.lineStrongColor, lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(.mpSnappy, value: configuration.isPressed)
            .onHover { hovering = $0 }
            .contentShape(Capsule())
    }
}

/// Square icon button for toolbars; pair every use with `.help(...)`.
struct MPIconButtonStyle: ButtonStyle {
    var size: CGFloat = 30
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        MPIconButtonBody(configuration: configuration, size: size, active: active)
    }
}

private struct MPIconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let size: CGFloat
    let active: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(MPFont.body(.medium))
            .foregroundStyle(active ? MeetingPilotDesign.accent : MeetingPilotDesign.textDimColor)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: MPRadius.control, style: .continuous)
                    .fill(active ? MeetingPilotDesign.accentTint : (hovering ? MeetingPilotDesign.hoverColor : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: MPRadius.control, style: .continuous)
                    .strokeBorder(MeetingPilotDesign.lineColor, lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .animation(.mpSnappy, value: configuration.isPressed)
            .onHover { hovering = $0 }
            .contentShape(Rectangle())
    }
}
