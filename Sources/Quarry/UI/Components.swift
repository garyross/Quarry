import SwiftUI

/// A large square button: a symbol over a short title. Used for the
/// Database Information tools, where people pick one of a few actions they
/// may not know the SQL for. A risky tool carries a warning mark.
struct TileButtonStyle: ButtonStyle {
    var isRisky = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(TileLabelStyle(isRisky: isRisky))
            .frame(maxWidth: .infinity, minHeight: Layout.tileHeight)
            .padding(Space.sm)
            .background(fill(pressed: configuration.isPressed), in: RoundedRectangle(cornerRadius: Radius.md))
            .overlay(alignment: .topTrailing) {
                if isRisky {
                    Image(systemName: StatusStyle.warningSymbol)
                        .symbolRenderingMode(.multicolor)
                        .padding(Space.sm)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: Radius.md))
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { inside in Motion.run(Motion.hover, reduceMotion: reduceMotion) { hovering = inside } }
    }

    private func fill(pressed: Bool) -> AnyShapeStyle {
        if pressed, isEnabled { return AnyShapeStyle(.fill) }
        if hovering, isEnabled { return AnyShapeStyle(.fill.secondary) }
        return AnyShapeStyle(.fill.tertiary)
    }
}

private struct TileLabelStyle: LabelStyle {
    let isRisky: Bool

    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: Space.sm) {
            configuration.icon
                .font(.title)
                .frame(height: Layout.tileIconHeight)
                .foregroundStyle(.tint)
            configuration.title
                .font(.callout)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
    }
}
