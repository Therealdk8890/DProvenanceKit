import Foundation

public actor FileTraceStore<T: TraceableEvent>: TraceStore {
    public let directoryURL: URL
    private var fileHandles: [UUID: FileHandle] = [:]
    
    public init(directoryURL: URL? = nil, directoryName: String = "DProvenanceKit") {
        if let provided = directoryURL {
            self.directoryURL = provided
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.directoryURL = appSupport.appendingPathComponent(directoryName).appendingPathComponent("Traces")
        }
        
        if !FileManager.default.fileExists(atPath: self.directoryURL.path) {
            try? FileManager.default.createDirectory(at: self.directoryURL, withIntermediateDirectories: true)
        }
    }
    
    deinit {
        for handle in fileHandles.values {
            try? handle.close()
        }
    }
    
    public func append(_ event: TraceEvent<T>) async throws {
        let fileURL = directoryURL.appendingPathComponent("\(event.runID.uuidString).jsonl")
        
        let data = try JSONEncoder().encode(event)
        var line = data
        line.append(Data("\n".utf8))
        
        let handle: FileHandle
        if let existing = fileHandles[event.runID] {
            handle = existing
        } else {
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
            handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            fileHandles[event.runID] = handle
        }
        
        try handle.write(contentsOf: line)
    }
    
    public func loadAllRuns() async throws -> [TraceRun<T>] {
        var runs: [TraceRun<T>] = []
        
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: directoryURL, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        let urls = enumerator.allObjects as? [URL] ?? []
        
        let decoder = JSONDecoder()
        
        for fileURL in urls {
            guard fileURL.pathExtension == "jsonl" else { continue }
            
            do {
                let data = try Data(contentsOf: fileURL)
                let lines = data.split(separator: UInt8(ascii: "\n"))
                
                var events: [TraceEvent<T>] = []
                for line in lines {
                    if let event = try? decoder.decode(TraceEvent<T>.self, from: line) {
                        events.append(event)
                    }
                }
                
                if let first = events.first {
                    let sortedEvents = events.sorted { $0.timestamp < $1.timestamp }
                    let run = TraceRun(runID: first.runID, contextID: first.contextID, events: sortedEvents)
                    runs.append(run)
                }
            } catch {
                print("Failed to parse run from \(fileURL): \(error)")
            }
        }
        
        return runs
    }
    
    public func queryRuns(_ dsl: TraceQueryDSL<T>) async throws -> [TraceRun<T>] {
        let runs = try await loadAllRuns()
        return runs.filter { dsl.ast.evaluate(run: $0) }
    }
}
