import SwiftUI

/// Monochrome palette and metrics. No gradients, no accent colours, no heavy shadows.
enum Mono {
    enum Palette {
        static let background = Color.white
        static let primary = Color.black
        static let secondary = Color(white: 0.52)
        static let tertiary = Color(white: 0.72)
        static let fill = Color(white: 0.955)
        static let separator = Color(white: 0.9)
        static let onPrimary = Color.white
    }

    enum Metrics {
        static let screenPadding: CGFloat = 24
        static let cornerRadius: CGFloat = 22
        static let controlHeight: CGFloat = 54
        static let connectButtonSize: CGFloat = 136
    }

    enum Animation {
        static let state = SwiftUI.Animation.spring(response: 0.42, dampingFraction: 0.86)
    }
}

/// Filled black capsule, the main call to action.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(Mono.Palette.onPrimary)
            .frame(maxWidth: .infinity, minHeight: Mono.Metrics.controlHeight)
            .background(Capsule().fill(isEnabled ? Mono.Palette.primary : Mono.Palette.tertiary))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// Light grey capsule for secondary actions.
struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(isEnabled ? Mono.Palette.primary : Mono.Palette.tertiary)
            .frame(maxWidth: .infinity, minHeight: Mono.Metrics.controlHeight)
            .background(Capsule().fill(Mono.Palette.fill))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// Round icon button used in headers.
struct IconButton: View {
    let systemName: String
    let accessibilityLabel: LocalizedStringKey
    var isLoading = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Mono.Palette.fill)
                if isLoading {
                    ProgressView().tint(Mono.Palette.primary)
                } else {
                    Image(systemName: systemName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Mono.Palette.primary)
                }
            }
            .frame(width: 42, height: 42)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(accessibilityLabel))
    }
}

/// Title row used at the top of sheets.
struct SheetHeader<Trailing: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center) {
            Text(title)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(Mono.Palette.primary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 12)
            trailing
        }
        .padding(.top, 28)
        .padding(.bottom, 20)
    }
}

/// Small grey caption with an icon, used for errors and hints (no colour accents).
struct NoticeText: View {
    let systemName: String
    let text: String

    var body: some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemName)
        }
        .font(.footnote)
        .foregroundStyle(Mono.Palette.secondary)
    }
}
