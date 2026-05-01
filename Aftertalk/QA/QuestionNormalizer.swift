import Foundation

/// Narrow proper-noun substitution pass for recognized questions.
///
/// Moonshine medium streaming catches most common-word mishearings the May 1
/// device test surfaced, but it has no acoustic prior for project-specific
/// proper nouns. "Aftertalk" gets transcribed as "afterthoughts" or "after
/// talk" because the model has never seen the token. Even a perfect speech
/// model wouldn't know that "OpenAI" is one word, not "open ai".
///
/// This helper runs between `QuestionASR.stop()` returning the recognized
/// text and the orchestrator dispatching it through retrieval. The whitelist
/// is intentionally narrow:
///
/// - Project-specific proper nouns ("Aftertalk", "Codex", "OpenAI", …)
/// - Stack-specific tokens that the LLM knows but the ASR mangles ("BM25",
///   "RRF", "Pyannote", "Kokoro", "Parakeet", "FluidAudio", "RAG")
///
/// What it deliberately does NOT do:
///
/// - No common-word rewrites. "Music" is not silently swapped to "meetings"
///   even though it might have been mistranscribed, because "music" can be
///   real meeting content.
/// - No sentence-shape reconstruction. If ASR says "The Times was in
///   unmentioned," we do not try to recover "How many times was X mentioned."
///   That's the editable-transcript feature's job, not this helper's.
///
/// Substitution is case-insensitive and bounded by word boundaries so a
/// phrase like "open AI" matches but "open AInsight" does not.
enum QuestionNormalizer {
    /// Project-specific tokens that always normalize to a canonical form.
    /// Keys are lowercased; values are the canonical replacement. Entries
    /// where the key has multiple words still match because we use a regex
    /// with `\b` boundaries.
    private static let projectTokens: [(pattern: String, replacement: String)] = [
        // Aftertalk family — the most common ASR miss in real device logs.
        ("afterthoughts", "Aftertalk"),
        ("after thought", "Aftertalk"),
        ("after talk", "Aftertalk"),
        ("after-talk", "Aftertalk"),
        ("aftertalk", "Aftertalk"),

        // OpenAI / Codex stack.
        ("open ai", "OpenAI"),
        ("openai", "OpenAI"),
        ("co-decks", "Codex"),
        ("co decks", "Codex"),
        ("codex", "Codex"),

        // Retrieval / TTS / ASR stack tokens. Casing matters because Kokoro
        // is a graphemic-input TTS and reads "rag" differently from "RAG".
        ("bm 25", "BM25"),
        ("bm25", "BM25"),
        ("rrf", "RRF"),
        ("reciprocal rank fusion", "Reciprocal Rank Fusion"),
        ("rag", "RAG"),
        ("kokoro", "Kokoro"),
        ("co-coro", "Kokoro"),
        ("pyannote", "Pyannote"),
        ("pi annot", "Pyannote"),
        ("parakeet", "Parakeet"),
        ("para keet", "Parakeet"),
        ("fluidaudio", "FluidAudio"),
        ("fluid audio", "FluidAudio"),
        ("moonshine", "Moonshine"),
        ("nl contextual", "NLContextual"),
        ("foundation models", "Foundation Models"),
    ]

    /// Apply the narrow whitelist to a recognized question, returning the
    /// canonical form. Returns the input unchanged if no patterns matched —
    /// callers should always be able to compare input vs output to know
    /// whether a substitution happened, for logging/diagnostics.
    static func normalize(_ recognized: String) -> String {
        var output = recognized
        for (pattern, replacement) in projectTokens {
            output = applyWordBoundedReplacement(
                in: output,
                pattern: pattern,
                replacement: replacement
            )
        }
        return output
    }

    /// Case-insensitive replacement bounded by word boundaries. Uses
    /// NSRegularExpression so we get proper Unicode `\b` semantics — a plain
    /// `String.replacingOccurrences` would happily rewrite "afterthoughts"
    /// inside "afterthoughtsmith" if such a word ever appeared.
    private static func applyWordBoundedReplacement(
        in text: String,
        pattern: String,
        replacement: String
    ) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: pattern)
        // The pattern itself can contain spaces (e.g. "open ai"). We bracket
        // the WHOLE phrase with `\b` so the replacement is whole-phrase.
        let bounded = #"\b\#(escaped)\b"#
        guard let regex = try? NSRegularExpression(pattern: bounded, options: [.caseInsensitive]) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: NSRegularExpression.escapedTemplate(for: replacement)
        )
    }
}
