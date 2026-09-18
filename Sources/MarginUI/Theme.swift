import MarginCore
import SwiftUI

public enum Theme {
    public static let track = Color.primary.opacity(0.10)

    /// Semantic system color for a window's severity. Normal usage uses the
    /// user's accent color, so the app feels native to their Mac.
    public static func tint(for severity: Severity) -> Color {
        switch severity {
        case .normal: return .accentColor
        case .warning: return .orange
        case .critical: return .red
        }
    }
}
