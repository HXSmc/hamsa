#if os(macOS) && canImport(Tokenizers)
import CoreML
import Foundation
import Tokenizers

/// T05b: e5-small on Core ML (fp16, CPU + Neural Engine) with the XLM-R SentencePiece (Unigram) tokenizer
/// from swift-transformers. Build the model with mac/Models/convert_e5.py.
public final class E5Embedder: Embedder, @unchecked Sendable {
    public enum EmbedError: Error { case noModel, badOutput }

    let model: MLModel
    let tokenizer: any Tokenizer

    init(model: MLModel, tokenizer: any Tokenizer) {
        self.model = model
        self.tokenizer = tokenizer
    }

    /// `dir` holds E5Small.mlmodelc + tokenizer.json / tokenizer_config.json / config.json.
    public static func load(dir: URL? = EmbedMath.defaultModelDir(), units: MLComputeUnits = .cpuAndNeuralEngine) async throws -> E5Embedder {
        guard let dir else { throw EmbedError.noModel }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = units
        let model = try MLModel(contentsOf: dir.appendingPathComponent("E5Small.mlmodelc"), configuration: cfg)
        let tok = try await AutoTokenizer.from(modelFolder: dir)
        return E5Embedder(model: model, tokenizer: tok)
    }

    /// Token ids with <s> ... </s>, before truncation and padding.
    public func tokenIDs(_ text: String) -> [Int] { tokenizer.encode(text: text) }

    public func embed(prefixed text: String) throws -> [Float] {
        let ids = EmbedMath.padded(tokenIDs(text))
        let input = MLFeatureValue(shapedArray: MLShapedArray<Int32>(scalars: ids, shape: [1, ids.count]))
        let out = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["input_ids": input]))
        guard let e = out.featureValue(for: "embedding")?.multiArrayValue else { throw EmbedError.badOutput }
        return (0..<e.count).map { e[$0].floatValue }
    }
}
#endif
