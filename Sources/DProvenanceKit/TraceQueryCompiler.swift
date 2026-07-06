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
            // A payload predicate isn't expressible in SQL, so it compiles to match-all.
            // Under NOT that would become `all EXCEPT all` = ∅ — a subset the post-filter
            // can't recover. So any NOT over a payload predicate selects all runs as
            // candidates and defers entirely to in-process evaluation.
            if node.hasPayloadPredicate {
                return CompiledSQLQuery(sql: "SELECT run_id FROM runs", bindings: [])
            }
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

        // MARK: - Temporal operators
        //
        // All temporal operators order events by `sequence`, the authoritative
        // per-run causal counter assigned at record time. They MUST NOT order by
        // `timestamp`: wall-clock values tie at sub-microsecond resolution under
        // bursts, which silently drops valid orderings and makes the SQL path
        // disagree with the in-memory `TraceQueryNode.evaluate` (which already
        // sorts by `sequence`). `idx_run_sequence` backs these comparisons.
        //
        // `.after` / `.before` also anchor to the FIRST occurrence of `step`
        // (`MIN(sequence)`), mirroring the in-memory evaluator's use of
        // `firstIndex(of: step)`. A naive "any step occurrence" join is weaker
        // for `.before` and reports false positives (a later `step` with an
        // earlier `precededBy` matches even though nothing precedes the *first*
        // `step`).

        case .after(let step, let followedBy):
            // `followedBy` occurs at or after the first occurrence of `step`.
            // `>=` mirrors the inclusive in-memory slice `types[firstIdx...]`.
            let sql = """
            SELECT DISTINCT e.run_id
            FROM trace_events e
            JOIN (
                SELECT run_id, MIN(sequence) AS anchor_seq
                FROM trace_events
                WHERE type = ?
                GROUP BY run_id
            ) anchor ON e.run_id = anchor.run_id
            WHERE e.type = ? AND e.sequence >= anchor.anchor_seq
            """
            return CompiledSQLQuery(sql: sql, bindings: [step, followedBy])

        case .before(let step, let precededBy):
            // `precededBy` occurs strictly before the first occurrence of `step`.
            // `<` mirrors the exclusive in-memory slice `types[..<firstIdx]`.
            let sql = """
            SELECT DISTINCT e.run_id
            FROM trace_events e
            JOIN (
                SELECT run_id, MIN(sequence) AS anchor_seq
                FROM trace_events
                WHERE type = ?
                GROUP BY run_id
            ) anchor ON e.run_id = anchor.run_id
            WHERE e.type = ? AND e.sequence < anchor.anchor_seq
            """
            return CompiledSQLQuery(sql: sql, bindings: [step, precededBy])

        case .sequence(let steps):
            if steps.isEmpty {
                return CompiledSQLQuery(sql: "SELECT run_id FROM runs", bindings: [])
            }
            if steps.count == 1 {
                return compileNode(TraceQueryNode<T>.containsStep(steps[0]))
            }

            // Subsequence existence: a strictly increasing chain of DISTINCT
            // events whose types match `steps` in order. Chaining on `sequence`
            // (strict `<`) guarantees distinct rows and the same subsequence
            // semantics as the in-memory greedy matcher.
            var sql = "SELECT DISTINCT e0.run_id\nFROM trace_events e0"
            for i in 1..<steps.count {
                sql += "\nJOIN trace_events e\(i) ON e\(i).run_id = e\(i - 1).run_id"
            }
            sql += "\nWHERE e0.type = ?"
            for i in 1..<steps.count {
                sql += " AND e\(i).type = ?"
            }
            for i in 1..<steps.count {
                sql += " AND e\(i - 1).sequence < e\(i).sequence"
            }
            return CompiledSQLQuery(sql: sql, bindings: steps)

        case .matchingPayload:
            // Payload-value predicates can't be expressed in SQL. Select all runs as
            // candidates (a superset); the SQLite store refines with in-process
            // `TraceQueryNode.evaluate` after hydrating each candidate.
            return CompiledSQLQuery(sql: "SELECT run_id FROM runs", bindings: [])
        }
    }
}
