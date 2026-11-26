import SwiftUI

extension View {
    func spotlightSurface<S: Shape>(_ shape: S, isDark: Bool) -> some View {
        background(windowSurfaceColor(isDark: isDark), in: shape)
            .clipShape(shape)
            .overlay {
                shape.stroke(isDark ? Color.white.opacity(0.14) : Color.black.opacity(0.1), lineWidth: 1)
            }
            .shadow(color: .black.opacity(isDark ? 0.35 : 0.15), radius: 18, y: 8)
            .transition(.scale(scale: 0.6, anchor: .leading).combined(with: .opacity))
    }
}

func windowSurfaceColor(isDark: Bool) -> Color {
    Color(white: isDark ? 0.14 : 0.96)
}
