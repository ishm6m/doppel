import Foundation

// CLI: `swift run --package-path Tools/CorpusGen CorpusGen --out ./TestCorpora/default [--count N] [--seed S]`
// Generates a deterministic synthetic corpus (PERFORMANCE.md §4). Output is git-ignored (TestCorpora/).
func arg(_ name: String, default def: String) -> String {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return def }
    return args[i + 1]
}

let outPath = arg("--out", default: "./TestCorpora/default")
let count = Int(arg("--count", default: "1000")) ?? 1000
let seed = UInt64(arg("--seed", default: "42")) ?? 42

let dir = URL(fileURLWithPath: outPath)
let gen = CorpusGenerator(spec: .init(count: count, seed: seed))
do {
    let docs = try gen.writeCorpus(to: dir)
    let unique = docs.count(where: { $0.kind == .unique })
    let exact = docs.count(where: { $0.kind == .exact })
    let near = docs.count(where: { $0.kind == .near })
    print("CorpusGen: wrote \(docs.count) files to \(dir.path) (seed \(seed))")
    print("  unique: \(unique)  exact-dupes: \(exact)  near-dupes: \(near)")
} catch {
    FileHandle.standardError.write(Data("CorpusGen failed: \(error)\n".utf8))
    exit(1)
}
