import Foundation

/// T05b: on-device text embedder. Vectors must match the brain's (brain/hamsa_brain/index/embed.py):
/// intfloat/multilingual-e5-small, "query: " / "passage: " prefixes, mean pooling, L2 normalized, 384 floats.
public protocol Embedder: Sendable {
    /// Embeds `text` exactly as given; callers add the e5 prefix (see `query` / `passage`).
    func embed(prefixed text: String) throws -> [Float]
}

public extension Embedder {
    /// A live question (also what the brain uses for its generated chunk questions).
    func query(_ text: String) throws -> [Float] { try embed(prefixed: "query: \(text)") }
    /// A document chunk; the brain embeds "heading\ntext".
    func passage(_ text: String) throws -> [Float] { try embed(prefixed: "passage: \(text)") }
}

/// Platform-free parts of the e5 port, kept here so Linux CI tests them.
public enum EmbedMath {
    /// Sequence lengths the Core ML model was converted for (mac/Models/convert_e5.py BUCKETS).
    public static let buckets = [16, 32, 64, 128, 256, 512]
    public static let padID = 1, eosID = 2

    /// sentence-transformers max_seq_length 512: keep the first 511 ids and end with </s>,
    /// then pad with <pad> up to the smallest bucket that fits (the model ignores pad positions).
    public static func padded(_ ids: [Int]) -> [Int32] {
        var ids = ids
        let maxLen = buckets.last!
        if ids.count > maxLen { ids = Array(ids.prefix(maxLen - 1)) + [eosID] }
        let len = buckets.first { $0 >= ids.count } ?? maxLen
        return ids.map(Int32.init) + [Int32](repeating: Int32(padID), count: len - ids.count)
    }

    public static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var s: Float = 0
        for i in 0..<min(a.count, b.count) { s += a[i] * b[i] }
        return s
    }

    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        let n = (dot(a, a) * dot(b, b)).squareRoot()
        return n > 0 ? dot(a, b) / n : 0
    }

    /// Default model folder: $HAMSA_MODELS/e5-small, then mac/Models/e5-small or Models/e5-small
    /// from the current directory, then ~/Library/Application Support/Hamsa/Models/e5-small.
    public static func defaultModelDir() -> URL? {
        let fm = FileManager.default
        var dirs: [String] = []
        if let env = ProcessInfo.processInfo.environment["HAMSA_MODELS"] { dirs.append("\(env)/e5-small") }
        dirs += ["mac/Models/e5-small", "Models/e5-small", "~/Library/Application Support/Hamsa/Models/e5-small"]
        return dirs.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
            .first { fm.fileExists(atPath: $0.appendingPathComponent("E5Small.mlmodelc").path) }
    }
}
