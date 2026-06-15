import Foundation

public struct CompiledSQLQuery {
    public let sql: String
    public let bindings: [String]
}

public enum TraceQueryCompiler {
    
    public static func compile<T: TraceableEvent>(node: TraceQueryNode<T>) -> CompiledSQLQuery {
        return compileNode(node)
    }
    
    private static func compileNode<T: TraceableEvent>(_ node: TraceQueryNode<T>) -> CompiledSQLQuery {
        switch node {
        case .and(let nodes):
            if nodes.isEmpty {
                return CompiledSQLQuery(sql: "SELECT run_id FROM runs", bindings: [])
            }
            let compiled = nodes.map { compileNode($0) }
            let sql = compiled.map { "\($0.sql)" }.joined(separator: "\nINTERSECT\n")
            let bindings = compiled.flatMap { $0.bindings }
            return CompiledSQLQuery(sql: sql, bindings: bindings)
            
        case .or(let nodes):
            if nodes.isEmpty {
                return CompiledSQLQuery(sql: "SELECT run_id FROM runs", bindings: [])
            }
            let compiled = nodes.map { compileNode($0) }
            let sql = compiled.map { "\($0.sql)" }.joined(separator: "\nUNION\n")
            let bindings = compiled.flatMap { $0.bindings }
            return CompiledSQLQuery(sql: sql, bindings: bindings)
            
        case .not(let node):
            let compiled = compileNode(node)
            return CompiledSQLQuery(
                sql: "SELECT run_id FROM runs EXCEPT\n\(compiled.sql)",
                bindings: compiled.bindings
            )
            
        case .contextIDEquals(let id):
            return CompiledSQLQuery(
                sql: "SELECT run_id FROM runs WHERE context_id = ?",
                bindings: [id]
            )
            
        case .engineNameEquals(let name):
            return CompiledSQLQuery(
                sql: "SELECT DISTINCT run_id FROM trace_events WHERE engine = ?",
                bindings: [name]
            )
            
        case .containsStep(let step):
            return CompiledSQLQuery(
                sql: "SELECT DISTINCT run_id FROM trace_events WHERE type = ?",
                bindings: [step]
            )
            
        case .missingStep(let step):
            return CompiledSQLQuery(
                sql: "SELECT run_id FROM runs EXCEPT SELECT DISTINCT run_id FROM trace_events WHERE type = ?",
                bindings: [step]
            )
            
        case .after(let step, let followedBy):
            let sql = """
            SELECT DISTINCT e1.run_id 
            FROM trace_events e1 
            JOIN trace_events e2 ON e1.run_id = e2.run_id 
            WHERE e1.type = ? AND e2.type = ? AND e2.timestamp > e1.timestamp
            """
            return CompiledSQLQuery(sql: sql, bindings: [step, followedBy])
            
        case .before(let step, let precededBy):
            let sql = """
            SELECT DISTINCT e1.run_id 
            FROM trace_events e1 
            JOIN trace_events e2 ON e1.run_id = e2.run_id 
            WHERE e1.type = ? AND e2.type = ? AND e2.timestamp < e1.timestamp
            """
            return CompiledSQLQuery(sql: sql, bindings: [step, precededBy])
            
        case .sequence(let steps):
            if steps.isEmpty {
                return CompiledSQLQuery(sql: "SELECT run_id FROM runs", bindings: [])
            }
            if steps.count == 1 {
                return compileNode(TraceQueryNode<T>.containsStep(steps[0]))
            }
            
            var sql = "SELECT DISTINCT e0.run_id\nFROM trace_events e0"
            for i in 1..<steps.count {
                sql += "\nJOIN trace_events e\(i) ON e\(i-1).run_id = e\(i).run_id"
            }
            sql += "\nWHERE e0.type = ?"
            for i in 1..<steps.count {
                sql += " AND e\(i).type = ?"
            }
            for i in 1..<steps.count {
                sql += " AND e\(i-1).timestamp < e\(i).timestamp"
            }
            return CompiledSQLQuery(sql: sql, bindings: steps)
        }
    }
}
