import XCTest
@testable import DProvenanceFoundationModels

/// The grammar is frozen: these exact strings are parsed by trace viewers
/// and compared across runs by the alignment engine.
final class FMSpanPathTests: XCTestCase {
    func testTurnPaths() {
        XCTAssertEqual(FMSpanPath.turn(0), "fm.turn.0")
        XCTAssertEqual(FMSpanPath.turn(3), "fm.turn.3")
        XCTAssertEqual(FMSpanPath.turn(3, sessionLabel: "drafting"), "fm[drafting].turn.3")
    }

    func testToolPaths() {
        XCTAssertEqual(
            FMSpanPath.tool(named: "WeatherTool", invocation: 0, turnIndex: 3),
            "fm.turn.3.tool.WeatherTool.0"
        )
        XCTAssertEqual(
            FMSpanPath.tool(named: "WeatherTool", invocation: 1, turnIndex: 3),
            "fm.turn.3.tool.WeatherTool.1"
        )
        XCTAssertEqual(
            FMSpanPath.tool(named: "WeatherTool", invocation: 1, turnIndex: 3, sessionLabel: "drafting"),
            "fm[drafting].turn.3.tool.WeatherTool.1"
        )
    }

    func testStandaloneToolPaths() {
        XCTAssertEqual(FMSpanPath.standaloneTool(named: "WeatherTool", invocation: 0), "fm.tool.WeatherTool.0")
        XCTAssertEqual(
            FMSpanPath.standaloneTool(named: "WeatherTool", invocation: 2, sessionLabel: "drafting"),
            "fm[drafting].tool.WeatherTool.2"
        )
    }

    func testDistinctInvocationsAreDistinct() {
        let first = FMSpanPath.tool(named: "WeatherTool", invocation: 0, turnIndex: 0)
        let second = FMSpanPath.tool(named: "WeatherTool", invocation: 1, turnIndex: 0)
        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(
            FMSpanPath.standaloneTool(named: "WeatherTool", invocation: 0),
            FMSpanPath.standaloneTool(named: "WeatherTool", invocation: 1)
        )
    }
}
