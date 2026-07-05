import Foundation

/// The frozen span-path grammar. Span ids ARE these strings (core's
/// `withSpan(named:)` sets spanID to the literal name), so same behavior
/// produces the same spanID/parentSpanID strings across runs — the property
/// the alignment engine's structural term depends on. Ungated pure string
/// logic so trace viewers can parse paths without the FoundationModels SDK.
public enum FMSpanPath {
    /// "fm.turn.3", or "fm[label].turn.3" with a session label.
    public static func turn(_ turnIndex: Int, sessionLabel: String? = nil) -> String {
        "\(prefix(sessionLabel)).turn.\(turnIndex)"
    }

    /// "fm.turn.3.tool.WeatherTool.0": the k-th call of a tool within a turn.
    public static func tool(named toolName: String, invocation k: Int, turnIndex: Int, sessionLabel: String? = nil) -> String {
        "\(turn(turnIndex, sessionLabel: sessionLabel)).tool.\(toolName).\(k)"
    }

    /// "fm.tool.WeatherTool.0": a TracedTool used with a plain
    /// LanguageModelSession, outside any traced turn.
    public static func standaloneTool(named toolName: String, invocation k: Int, sessionLabel: String? = nil) -> String {
        "\(prefix(sessionLabel)).tool.\(toolName).\(k)"
    }

    private static func prefix(_ sessionLabel: String?) -> String {
        guard let sessionLabel else { return "fm" }
        return "fm[\(sessionLabel)]"
    }
}
