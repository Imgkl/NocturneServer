import AsyncHTTPClient
import Foundation
import NIOCore

/// TypeSafe's Jev (`POST /v1/systemone`): a block of text plus named questions in, a
/// probability per question out. One request per film carries a yes/no question per mood and
/// two primary-mood choices, the second with the options shuffled by the film's id.
struct JevClient: DecisionClassifying, Sendable {
    static let defaultBaseURL = "https://api.typesafe.ai"
    static let defaultModel = "jev-1.13.0"
    static let modelSetting = "classifier.jev_model"
    static let apiKeySetting = "jev_api_key"
    static let noneOption = "none"
    static let primaryInstructions =
        "Which mood is this film's primary residue, the feeling a viewer carries home after the credits? "
        + "Judge the whole film by its dominant register, never one scene. Pick none only when no mood fits well."

    let outbound: OutboundClient
    let buckets: [String: MoodBucket]
    var baseURL: String = Self.defaultBaseURL
    var model: String = Self.defaultModel
    let provider = "typesafe"

    // MARK: Request

    /// Question keys are snake_case (`mood_ha_ha_ha`); option keys keep the slugs.
    static func questionKey(for slug: String) -> String { "mood_" + slug.replacingOccurrences(of: "-", with: "_") }

    static func slug(forQuestionKey key: String, in buckets: [String: MoodBucket]) -> String? {
        guard key.hasPrefix("mood_") else { return nil }
        let body = String(key.dropFirst(5))
        return buckets.keys.first { questionKey(for: $0) == "mood_" + body }
    }

    /// Yes/no instructions for one mood: the residue, the checklist and the redirects.
    /// The owner's learned rules for one mood come last and override the conditions before them.
    static func moodInstructions(slug: String, bucket: MoodBucket, rules: [String] = []) -> String {
        var lines = ["Does this film fit the mood \"\(bucket.title)\"? Judge the whole film, not one scene."]
        lines.append(bucket.description.trimmingCharacters(in: .whitespacesAndNewlines))
        if let q = bucket.qualifies, !q.isEmpty {
            lines.append("It fits only when every condition holds: " + q.enumerated().map { "(\($0.offset + 1)) \($0.element)" }.joined(separator: " "))
        }
        if let misses = bucket.anchorsMiss, !misses.isEmpty {
            lines.append("Not for: " + misses.joined(separator: "; "))
        }
        lines += overrides(rules)
        return lines.joined(separator: " ")
    }

    static func overrides(_ rules: [String]) -> [String] {
        rules.isEmpty ? [] : ["The owner's rules for this mood override any condition or exclusion above when they conflict: " + rules.joined(separator: " ")]
    }

    /// Pass 2 order: a deterministic shuffle seeded by the film id whose first option differs from pass 1's.
    static func shuffledOrder(_ order: [String], seed: String) -> [String] {
        var generator = SeededGenerator(seed: "jev:" + seed)
        var a = order
        if a.count > 1 {
            for i in stride(from: a.count - 1, to: 0, by: -1) {
                let j = Int(generator.next() % UInt64(i + 1))
                a.swapAt(i, j)
            }
            if a[0] == order[0] {
                let j = 1 + Int(generator.next() % UInt64(a.count - 1))
                a.swapAt(0, j)
            }
        }
        return a
    }

    /// The request body as JSON text. Option order matters to the second pass, so the object is
    /// written by hand in order rather than through a dictionary.
    static func body(buckets: [String: MoodBucket], model: String, textBlock: String, guide: String?, moodRules: [String: [String]] = [:], jellyfinId: String) -> (json: String, order1: [String], order2: [String]) {
        let slugs = buckets.keys.sorted()
        let order1 = slugs + [noneOption]
        let order2 = shuffledOrder(order1, seed: jellyfinId)
        var instructions = primaryInstructions
        if let guide = guide?.trimmingCharacters(in: .whitespacesAndNewlines), !guide.isEmpty {
            instructions += "\n\nThe owner's filing guide. When it conflicts with a mood description, the guide wins:\n" + guide
        }
        func criterion(_ slug: String) -> String {
            if slug == noneOption { return jsonString("None of these moods fits the film well") }
            let b = buckets[slug]!
            var covers = b.description.trimmingCharacters(in: .whitespacesAndNewlines)
            if let q = b.qualifies, !q.isEmpty { covers += " Qualifies when: " + q.joined(separator: " ") }
            if let m = b.anchorsMiss, !m.isEmpty { covers += " Not for: " + m.joined(separator: "; ") }
            for line in overrides(moodRules[slug] ?? []) { covers += " " + line }
            let typical = (b.anchorsFit ?? []).joined(separator: "; ")
            return "{\"covers\":\(jsonString(covers)),\"typical\":\(jsonString(typical))}"
        }
        func choice(_ order: [String]) -> String {
            let criteria = order.map { "\(jsonString($0)):\(criterion($0))" }.joined(separator: ",")
            return "{\"type\":\"choice\",\"instructions\":\(jsonString(instructions)),\"criteria\":{\(criteria)}}"
        }
        var questions: [String] = []
        for slug in slugs {
            questions.append("\(jsonString(questionKey(for: slug))):{\"type\":\"noul\",\"instructions\":\(jsonString(moodInstructions(slug: slug, bucket: buckets[slug]!, rules: moodRules[slug] ?? [])))}")
        }
        questions.append("\"primary_pass1\":\(choice(order1))")
        questions.append("\"primary_pass2\":\(choice(order2))")
        let json = "{\"state\":{\"film\":\(jsonString(textBlock))},\"model\":\(jsonString(model)),\"questions\":{\(questions.joined(separator: ","))}}"
        return (json, order1, order2)
    }

    static func jsonString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    // MARK: Response

    struct Response: Decodable, Sendable {
        struct Usage: Decodable, Sendable {
            let inputTokens: Int?
            enum CodingKeys: String, CodingKey { case inputTokens = "input_tokens" }
        }
        struct Answer: Decodable, Sendable {
            let noul: Double?
            let choice: String?
            let probabilities: [String: Double]?
            let confidence: Double?
        }
        let model: String?
        let usage: Usage?
        let answers: [String: Answer]?
    }

    /// The vendor's answers as a `ClassifierAnswer`. Unknown question keys are ignored; a choice
    /// whose pick is not one of its options is dropped (the unsure signal then fires).
    static func parse(_ response: Response, buckets: [String: MoodBucket], order1: [String], provider: String, fallbackModel: String, rawJson: String) -> ClassifierAnswer {
        var probabilities: [String: Double] = [:]
        var passes: [String: ClassifierChoice] = [:]
        for (key, answer) in response.answers ?? [:] {
            if let slug = slug(forQuestionKey: key, in: buckets), let p = answer.noul {
                probabilities[slug] = min(1, max(0, p))
            } else if key == "primary_pass1" || key == "primary_pass2" {
                guard let choice = answer.choice, order1.contains(choice), let probs = answer.probabilities else { continue }
                passes[key] = ClassifierChoice(choice: choice, probabilities: probs, confidence: answer.confidence ?? 0)
            }
        }
        return ClassifierAnswer(
            provider: provider, model: response.model ?? fallbackModel, probabilities: probabilities,
            pass1: passes["primary_pass1"], pass2: passes["primary_pass2"], rawJson: rawJson,
            inputTokens: response.usage?.inputTokens ?? 0)
    }

    // MARK: Call

    func classify(textBlock: String, guide: String?, moodRules: [String: [String]], jellyfinId: String, apiKey: String, context: CallContext) async throws -> ClassifierAnswer {
        let built = Self.body(buckets: buckets, model: model, textBlock: textBlock, guide: guide, moodRules: moodRules, jellyfinId: jellyfinId)
        var request = HTTPClientRequest(url: "\(baseURL)/v1/systemone")
        request.method = .POST
        request.headers.add(name: "authorization", value: "Bearer \(apiKey)")
        request.headers.add(name: "content-type", value: "application/json")
        request.body = .bytes(Data(built.json.utf8))
        let response = try await outbound.send(
            provider: provider, endpoint: "/v1/systemone", model: model, request: request,
            timeout: .seconds(60), context: context
        ) { response in
            guard (200..<300).contains(response.status), let decoded = try? response.decode(Response.self) else { return .none }
            return CallUnits(inputTokens: decoded.usage?.inputTokens, questions: decoded.answers?.count)
        }
        let decoded = try response.decode(Response.self)
        return Self.parse(decoded, buckets: buckets, order1: built.order1, provider: provider, fallbackModel: model, rawJson: response.bodyText)
    }
}

/// A small deterministic generator (SplitMix64) seeded from a string, so a film's pass-2 order
/// is the same on every run and in the tests.
struct SeededGenerator {
    private var state: UInt64

    init(seed: String) {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in seed.utf8 {
            h ^= UInt64(byte)
            h = h &* 0x0000_0100_0000_01b3
        }
        state = h
    }

    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }
}
