import Foundation
import Hummingbird
import Logging

/// Model and budget settings for the tagger, plus the enrichment summary the Settings page
/// shows. Additive next to the legacy `/settings/keys` and `/settings/info` routes.
struct ModelSettingsRoutes: Sendable {
    static let readerModels = ["claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5"]
    static let strongModels = ["claude-opus-5-5", "claude-sonnet-5-5"]

    static let classifierProviders = ["none", "jev"]

    let settings: SettingsStore
    let budget: BudgetGuard
    let coverage: EnrichCoverageJob
    let config: NocturneConfiguration
    /// The classifier of record, for the Test button.
    let classifier: DecisionClassifying?
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
        let classifier_provider: String
        let classifier_providers: [String]
        let classifier_model: String
        let jev_key_set: Bool
        let policy_version: String
        let policy_versions: [String]
        let floors: [String: Double]
        let high: [String: Double]
        let guide_version: Int
    }

    struct UpdateBody: Codable {
        let reader_model: String?
        let strong_model: String?
        let monthly_budget_usd: Double?
        let model_fallback: Bool?
        let classifier_provider: String?
        let classifier_model: String?
        let policy_version: String?
        let floors: [String: Double]?
        let high: [String: Double]?
    }

    struct TestResult: Codable {
        let ok: Bool
        let model: String?
        let answered: Int?
        let error: String?
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
            if let provider = body.classifier_provider?.trimmingCharacters(in: .whitespaces) {
                guard Self.classifierProviders.contains(provider) else { throw HTTPError(.badRequest, message: "classifier_provider must be one of \(Self.classifierProviders)") }
                try await self.settings.set(PolicyConfig.providerSetting, provider)
            }
            if let model = body.classifier_model?.trimmingCharacters(in: .whitespaces) {
                guard !model.isEmpty else { throw HTTPError(.badRequest, message: "classifier_model cannot be empty") }
                try await self.settings.set(JevClient.modelSetting, model)
            }
            if let version = body.policy_version?.trimmingCharacters(in: .whitespaces) {
                guard PolicyEngine.versions.contains(version) else { throw HTTPError(.badRequest, message: "policy_version must be one of \(PolicyEngine.versions)") }
                try await self.settings.set(PolicyConfig.versionSetting, version)
            }
            if let floors = body.floors {
                try self.validate(floors, name: "floors")
                try await self.settings.set(PolicyConfig.floorsSetting, PolicyConfig.encode(floors))
            }
            if let high = body.high {
                try self.validate(high, name: "high")
                try await self.settings.set(PolicyConfig.highSetting, PolicyConfig.encode(high))
            }
            return try jsonResponse(try await self.current())
        }

        // POST /settings/jev-test: one small classification with the stored key.
        group.post("jev-test") { _, _ in
            guard let classifier = self.classifier else { return try jsonResponse(TestResult(ok: false, model: nil, answered: nil, error: "no classifier built in")) }
            guard let key = try await self.settings.get(JevClient.apiKeySetting), !key.isEmpty else {
                return try jsonResponse(TestResult(ok: false, model: nil, answered: nil, error: "Jev key missing"))
            }
            let block = "# Identity\nTitle: Test Film (2001)\n\n# Plot (Wikipedia, full, contains spoilers)\nA man wakes in the same day over and over until he learns to be kind.\n"
            do {
                let answer = try await classifier.classify(textBlock: block, guide: nil, jellyfinId: "settings-test", apiKey: key, context: .none)
                return try jsonResponse(TestResult(ok: true, model: answer.model, answered: answer.probabilities.count, error: nil))
            } catch {
                return try jsonResponse(TestResult(ok: false, model: nil, answered: nil, error: String(describing: error)))
            }
        }
    }

    private func validate(_ table: [String: Double], name: String) throws {
        for (slug, value) in table {
            guard config.moodBuckets[slug] != nil else { throw HTTPError(.badRequest, message: "\(name): unknown mood \(slug)") }
            guard (0...1).contains(value) else { throw HTTPError(.badRequest, message: "\(name): \(slug) must be between 0 and 1") }
        }
    }

    func current() async throws -> ModelSettings {
        let reader = try await settings.get(ReaderService.modelSetting).flatMap { $0.isEmpty ? nil : $0 } ?? ReaderService.defaultModel
        let strong = try await settings.get(FallbackSynopsisService.modelSetting).flatMap { $0.isEmpty ? nil : $0 } ?? FallbackSynopsisService.defaultModel
        let fallback = (try await settings.get(FallbackSynopsisService.enabledSetting))?.lowercased() == "on"
        let policy = try await PolicyConfig.load(settings: settings, slugs: config.moodBuckets.keys)
        let classifierModel = try await settings.get(JevClient.modelSetting).flatMap { $0.isEmpty ? nil : $0 } ?? JevClient.defaultModel
        let jevKey = (try await settings.get(JevClient.apiKeySetting)) ?? ""
        return ModelSettings(
            reader_model: reader,
            strong_model: strong,
            reader_models: Self.readerModels,
            strong_models: Self.strongModels,
            monthly_budget_usd: try await budget.cap(),
            budget_spent_usd: try await budget.monthToDateSpend(),
            model_fallback: fallback,
            enrichment: try await coverage.summary(),
            classifier_provider: policy.provider.rawValue,
            classifier_providers: Self.classifierProviders,
            classifier_model: classifierModel,
            jev_key_set: !jevKey.isEmpty,
            policy_version: policy.version,
            policy_versions: PolicyEngine.versions,
            floors: policy.floors,
            high: policy.high,
            guide_version: try await GuideStore.version(settings: settings))
    }
}
