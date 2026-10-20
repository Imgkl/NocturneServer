import Testing

@testable import NocturneServer

@Suite struct PriceTableTests {
    @Test func haikuCostWithCacheReads() {
        let units = CallUnits(inputTokens: 1_000, outputTokens: 300, cacheReadTokens: 9_000)
        let cost = PriceTable.current.cost(provider: "anthropic", model: "claude-haiku-5-5", units: units)
        #expect(abs(cost - 0.00034) < 1e-9)
    }

    @Test func opus47CostMatchesTodayDefaults() {
        // Roughly one film on the pre-rewrite tagger: 10K uncached input, 300 output.
        let units = CallUnits(inputTokens: 10_000, outputTokens: 300)
        let cost = PriceTable.current.cost(provider: "anthropic", model: "claude-opus-4-7", units: units)
        #expect(abs(cost - 0.0575) < 1e-9)
    }

    @Test func unknownModelCostsZero() {
        let cost = PriceTable.current.cost(provider: "anthropic", model: "claude-unknown-9", units: CallUnits(inputTokens: 1_000_000))
        #expect(cost == 0)
    }

    @Test func providerFallbackWhenModelIsNil() {
        #expect(PriceTable.current.cost(provider: "wikimedia", model: nil, units: CallUnits(calls: 1)) == 0)
        #expect(PriceTable.current.price(provider: "omdb", model: nil) != nil)
    }

    @Test func perSearchUnitsAreCarriedEvenAtZeroPrice() {
        let p = PriceTable.current.price(provider: "anthropic", model: "web_search")
        #expect(p?.checkedOn == "unverified")
        #expect(PriceTable.current.cost(provider: "anthropic", model: "web_search", units: CallUnits(searches: 3)) == 0)
    }
}
