import Foundation
import Logging

/// Billable units of one outbound call. Every field is optional so a provider only reports
/// what it bills for. Stored as `api_calls.units_json`.
struct CallUnits: Codable, Sendable, Equatable {
    var inputTokens: Int? = nil
    var outputTokens: Int? = nil
    var cacheReadTokens: Int? = nil
    var cacheWriteTokens: Int? = nil
    var questions: Int? = nil
    var images: Int? = nil
    var searches: Int? = nil
    var calls: Int? = nil

    static let none = CallUnits()
}

/// Price of one model or endpoint, in USD. Token prices are per million tokens.
struct ModelPrice: Sendable {
    var inputPerM: Double = 0
    var outputPerM: Double = 0
    var cacheReadPerM: Double = 0
    var cacheWritePerM: Double = 0
    var perSearch: Double = 0
    var perCall: Double = 0
    /// The date the price was checked against the vendor's pricing page.
    var checkedOn: String
}

/// Single source of truth for cost metering. Keys are `provider/model`, with a bare `provider`
/// key as the fallback for endpoints that bill per call rather than per model.
struct PriceTable: Sendable {
    let entries: [String: ModelPrice]
    private let logger = Logger(label: "PriceTable")

    init(entries: [String: ModelPrice]) {
        self.entries = entries
    }

    /// Prices as of 2026-10-21 (Anthropic first-party API rates). Cache reads are 10% of input
    /// and cache writes 125% on the 4.x and Haiku lines; the 5.5 lines publish their own read rate.
    static let current = PriceTable(entries: [
        "anthropic/claude-haiku-5-5": ModelPrice(inputPerM: 0.10, outputPerM: 0.50, cacheReadPerM: 0.01, cacheWritePerM: 0.125, checkedOn: "2026-10-21"),
        "anthropic/claude-sonnet-5-5": ModelPrice(inputPerM: 2.00, outputPerM: 10.00, cacheReadPerM: 0.20, cacheWritePerM: 2.50, checkedOn: "2026-10-21"),
        "anthropic/claude-opus-5-5": ModelPrice(inputPerM: 4.00, outputPerM: 20.00, cacheReadPerM: 0.20, cacheWritePerM: 5.00, checkedOn: "2026-10-21"),
        "anthropic/claude-opus-4-7": ModelPrice(inputPerM: 5.00, outputPerM: 25.00, cacheReadPerM: 0.50, cacheWritePerM: 6.25, checkedOn: "2026-10-21"),
        // Web search is billed per search on top of tokens. Price not confirmed yet; recorded as
        // `searches` in units so it can be re-costed once the number is in.
        "anthropic/web_search": ModelPrice(perSearch: 0, checkedOn: "unverified"),
        // TypeSafe Jev: input tokens only, published $0.042 per million (X-Cache's price table, 9 Oct 2026).
        "typesafe/jev-1.13.0": ModelPrice(inputPerM: 0.042, checkedOn: "2026-10-09"),
        "typesafe": ModelPrice(inputPerM: 0.042, checkedOn: "2026-10-09"),
        "wikimedia": ModelPrice(checkedOn: "2026-10-21"),
        "wikidata": ModelPrice(checkedOn: "2026-10-21"),
        "omdb": ModelPrice(checkedOn: "2026-10-21"),
    ])

    func price(provider: String, model: String?) -> ModelPrice? {
        if let model, let p = entries["\(provider)/\(model)"] { return p }
        return entries[provider]
    }

    /// Cost in USD for one call. Unknown provider or model costs 0 and is logged once per call so
    /// the gap is visible rather than silently free.
    func cost(provider: String, model: String?, units: CallUnits) -> Double {
        guard let p = price(provider: provider, model: model) else {
            logger.warning("No price for \(provider)/\(model ?? "-"); metering this call at $0")
            return 0
        }
        let tokens =
            Double(units.inputTokens ?? 0) * p.inputPerM
            + Double(units.outputTokens ?? 0) * p.outputPerM
            + Double(units.cacheReadTokens ?? 0) * p.cacheReadPerM
            + Double(units.cacheWriteTokens ?? 0) * p.cacheWritePerM
        // Web search is a separate line item on top of the model's tokens.
        let perSearch = entries["\(provider)/web_search"]?.perSearch ?? p.perSearch
        return tokens / 1_000_000
            + Double(units.searches ?? 0) * perSearch
            + Double(units.calls ?? 0) * p.perCall
    }
}
