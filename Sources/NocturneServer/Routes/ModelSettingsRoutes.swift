import Foundation
import Hummingbird
import Logging

/// Model and budget settings for the tagger, plus the enrichment summary the Settings page
/// shows. Additive next to the legacy `/settings/keys` and `/settings/info` routes.
struct ModelSettingsRoutes: Sendable {
    static let readerModels = ["claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5"]
    static let strongModels = ["claude-opus-5-5", "claude-sonnet-5-5"]

    let settings: SettingsStore
    let budget: BudgetGuard
    let coverage: EnrichCoverageJob
    let logger = Logger(label: "ModelSettingsRoutes")

    struct ModelSettings: Codable {
        let reader_model: String
        let strong_model: String
        let reader_models: [String]
        let strong_models: [String]
        let monthly_budget_usd: Double?
        let budget_spent_usd: Double
        let model_fallback: Bool
        let enrichment: [String: Int]
    }

    struct UpdateBody: Codable {
        let reader_model: String?
        let strong_model: String?
        let monthly_budget_usd: Double?
        let model_fallback: Bool?
    }

    func addRoutes(to api: RouterGroup<BasicRequestContext>) {
        let group = api.group("settings")

        group.get("models") { _, _ in
            try jsonResponse(try await self.current())
        }

        group.post("models") { request, context in
            let body = try await request.decode(as: UpdateBody.self, context: context)
            if let reader = body.reader_model?.trimmingCharacters(in: .whitespaces) {
                guard !reader.isEmpty else { throw HTTPError(.badRequest, message: "reader_model cannot be empty") }
                try await self.settings.set(ReaderService.modelSetting, reader)
            }
            if let strong = body.strong_model?.trimmingCharacters(in: .whitespaces) {
                guard !strong.isEmpty else { throw HTTPError(.badRequest, message: "strong_model cannot be empty") }
                try await self.settings.set(FallbackSynopsisService.modelSetting, strong)
            }
            if let cap = body.monthly_budget_usd {
                guard cap >= 0 else { throw HTTPError(.badRequest, message: "monthly_budget_usd cannot be negative") }
                try await self.settings.set(BudgetGuard.settingKey, String(cap))
            }
            if let fallback = body.model_fallback {
                try await self.settings.set(FallbackSynopsisService.enabledSetting, fallback ? "on" : "off")
            }
            return try jsonResponse(try await self.current())
        }
    }

    func current() async throws -> ModelSettings {
        let reader = try await settings.get(ReaderService.modelSetting).flatMap { $0.isEmpty ? nil : $0 } ?? ReaderService.defaultModel
        let strong = try await settings.get(FallbackSynopsisService.modelSetting).flatMap { $0.isEmpty ? nil : $0 } ?? FallbackSynopsisService.defaultModel
        let fallback = (try await settings.get(FallbackSynopsisService.enabledSetting))?.lowercased() == "on"
        return ModelSettings(
            reader_model: reader,
            strong_model: strong,
            reader_models: Self.readerModels,
            strong_models: Self.strongModels,
            monthly_budget_usd: try await budget.cap(),
            budget_spent_usd: try await budget.monthToDateSpend(),
            model_fallback: fallback,
            enrichment: try await coverage.summary())
    }
}
