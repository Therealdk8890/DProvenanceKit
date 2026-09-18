import Foundation
import E2EDecisionPathDemoLib

// Keep this @main entry point out of a file named main.swift. Xcode's generated
// package scheme otherwise treats it as top-level code for iOS builds.

@main
struct E2EDecisionPathDemo {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        var outputDir: URL?
        var keep = false

        var i = 0
        while i < args.count {
            let arg = args[i]
            if arg == "--keep" {
                keep = true
            } else if arg == "--output-dir", i + 1 < args.count {
                i += 1
                outputDir = URL(fileURLWithPath: args[i], isDirectory: true)
                keep = true
            } else if arg.hasPrefix("--output-dir=") {
                let path = String(arg.dropFirst("--output-dir=".count))
                outputDir = URL(fileURLWithPath: path, isDirectory: true)
                keep = true
            } else if arg == "--help" || arg == "-h" {
                print("""
                usage: swift run E2EDecisionPathDemo [--output-dir PATH] [--keep]

                End-to-end decision-path demo
                (Instrument → Record → Baseline → Gate → Attest → Verify).
                """)
                exit(0)
            } else {
                fputs("unknown argument: \(arg)\n", stderr)
                exit(2)
            }
            i += 1
        }

        if outputDir == nil,
           let env = ProcessInfo.processInfo.environment["DPROV_E2E_OUT"],
           !env.isEmpty {
            outputDir = URL(fileURLWithPath: env, isDirectory: true)
            keep = true
        }

        let code = await E2EDecisionPathDemoRunner.run(
            options: .init(outputDirectory: outputDir, keep: keep)
        )
        exit(Int32(code))
    }
}
