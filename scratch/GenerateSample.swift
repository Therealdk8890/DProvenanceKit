import Foundation
import DProvenanceKit

enum SampleDecision: TraceableEvent {
    case initialization
    case queryDB(query: String)
    case fetchedRecords(count: Int)
    case llmPrompt(prompt: String)
    case llmResponse(response: String)
    case failure(reason: String)
    
    var typeIdentifier: String {
        switch self {
        case .initialization: return "initialization"
        case .queryDB: return "queryDB"
        case .fetchedRecords: return "fetchedRecords"
        case .llmPrompt: return "llmPrompt"
        case .llmResponse: return "llmResponse"
        case .failure: return "failure"
        }
    }
    
    var priority: TracePriority {
        switch self {
        case .initialization: return .structural
        case .queryDB: return .telemetry
        case .fetchedRecords: return .diagnostic
        case .llmPrompt, .llmResponse: return .diagnostic
        case .failure: return .critical
        }
    }
}

@main
struct GenerateSample {
    static func main() async throws {
        let url = URL(fileURLWithPath: "sample_traces.sqlite")
        try? FileManager.default.removeItem(at: url)
        
        let store = try SQLiteTraceStore<SampleDecision>(fileURL: url)
        
        await DProvenanceKit<SampleDecision>.run(contextID: "user_request_123", store: store) { @Sendable in
            DProvenanceKit<SampleDecision>.record(.initialization)
            
            await DProvenanceKit<SampleDecision>.withEngine(name: "DataFetcher") { @Sendable in
                await DProvenanceKit<SampleDecision>.withSpan { @Sendable in
                    DProvenanceKit<SampleDecision>.record(.queryDB(query: "SELECT * FROM users"))
                    DProvenanceKit<SampleDecision>.record(.fetchedRecords(count: 42))
                }
            }
            
            await DProvenanceKit<SampleDecision>.withEngine(name: "LLM_Agent") { @Sendable in
                await DProvenanceKit<SampleDecision>.withSpan { @Sendable in
                    DProvenanceKit<SampleDecision>.record(.llmPrompt(prompt: "Summarize 42 users"))
                    
                    await DProvenanceKit<SampleDecision>.withSpan { @Sendable in
                        DProvenanceKit<SampleDecision>.record(.llmResponse(response: "Here is the summary..."))
                    }
                }
            }
        }
        
        try await store.flush()
        print("Generated sample_traces.sqlite")
    }
}
