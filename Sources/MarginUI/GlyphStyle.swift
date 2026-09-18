import MarginCore

public enum GlyphStyle: String, CaseIterable, Identifiable {
    case levels
    case ring
    case text

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .levels: return "Levels"
        case .ring: return "Ring"
        case .text: return "Compact text"
        }
    }
}
