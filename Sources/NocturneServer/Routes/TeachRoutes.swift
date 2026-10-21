import Foundation
import Hummingbird
import Logging

/// Teach: the boundary groups, one-tap answers, rule preview and acceptance.
struct TeachRoutes: Sendable {
    let teach: TeachService
    let settings: SettingsStore
    let config: NocturneConfiguration

    struct GroupsResponse: Codable {
        let groups: [TeachService.Group]
        let guideVersion: Int
    }
    struct AnswerBody: Codable {
        let jellyfinId: String
        let boundary: String
        let answer: String
    }
    struct BoundaryBody: Codable {
        let boundary: String
    }
    struct RulesResponse: Codable {
        let rules: [String]
    }
    struct AcceptBody: Codable {
        let boundary: String
        let rules: [String]
    }
    struct AnswerResponse: Codable {
        let ok: Bool
        let answer: String
    }

    func addRoutes(to api: RouterGroup<BasicRequestContext>) {
        let group = api.group("admin").group("teach")

        group.get("") { _, _ in
            try jsonResponse(GroupsResponse(groups: try await self.teach.groups(), guideVersion: try await GuideStore.version(settings: self.settings)))
        }

        group.post("answer") { request, context in
            let body = try await request.decode(as: AnswerBody.self, context: context)
            do {
                let row = try await self.teach.answer(jellyfinId: body.jellyfinId, boundaryKey: body.boundary, answer: body.answer)
                return try jsonResponse(AnswerResponse(ok: true, answer: row.answer))
            } catch let error as TeachError {
                throw HTTPError(.badRequest, message: error.description)
            }
        }

        // POST /admin/teach/rules/preview: the strong model drafts rules from the answers (about $0.05).
        group.post("rules/preview") { request, context in
            let body = try await request.decode(as: BoundaryBody.self, context: context)
            guard let key = try await self.settings.get(TaggerPipeline.apiKeySetting), !key.isEmpty else {
                throw HTTPError(.badRequest, message: "Anthropic API key is not configured")
            }
            do {
                return try jsonResponse(RulesResponse(rules: try await self.teach.previewRules(boundaryKey: body.boundary, apiKey: key)))
            } catch let error as TeachError {
                throw HTTPError(.badRequest, message: error.description)
            }
        }

        // POST /admin/teach/rules/accept: the rules join the guide and the boundary's films are re-graded.
        group.post("rules/accept") { request, context in
            let body = try await request.decode(as: AcceptBody.self, context: context)
            do {
                return try jsonResponse(try await self.teach.acceptRules(boundaryKey: body.boundary, rules: body.rules))
            } catch let error as TeachError {
                throw HTTPError(.badRequest, message: error.description)
            }
        }
    }
}

/// The guide: the manual text (editable) and the learned rules (deletable one by one).
struct GuideRoutes: Sendable {
    let teach: TeachService
    let settings: SettingsStore
    let config: NocturneConfiguration

    struct GuideResponse: Codable {
        let manual: String
        /// True while the manual text is the bundled one, not an edit.
        let bundled: Bool
        let learned: [GuideStore.LearnedRule]
        let version: Int
    }
    struct ManualBody: Codable {
        let manual: String
    }

    func addRoutes(to api: RouterGroup<BasicRequestContext>) {
        let group = api.group("settings").group("guide")

        group.get("") { _, _ in
            try jsonResponse(try await self.current())
        }

        group.put("") { request, context in
            let body = try await request.decode(as: ManualBody.self, context: context)
            let text = body.manual.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw HTTPError(.badRequest, message: "the guide cannot be empty") }
            _ = try await GuideStore.setManual(text, settings: self.settings)
            return try jsonResponse(try await self.current())
        }

        // PUT /settings/guide/reset: back to the bundled text.
        group.put("reset") { _, _ in
            _ = try await GuideStore.setManual("", settings: self.settings)
            return try jsonResponse(try await self.current())
        }

        group.delete("learned/:index") { _, context in
            guard let index = Int(try context.parameters.require("index")) else { throw HTTPError(.badRequest, message: "index must be a number") }
            do {
                _ = try await self.teach.removeRule(at: index)
            } catch let error as TeachError {
                throw HTTPError(.notFound, message: error.description)
            }
            return try jsonResponse(try await self.current())
        }
    }

    func current() async throws -> GuideResponse {
        let stored = try await settings.get(GuideStore.manualSetting)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return GuideResponse(
            manual: stored.isEmpty ? config.autoTaggingPrompt : stored,
            bundled: stored.isEmpty,
            learned: try await GuideStore.learned(settings: settings),
            version: try await GuideStore.version(settings: settings))
    }
}
