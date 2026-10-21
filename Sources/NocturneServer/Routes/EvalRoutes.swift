import Foundation
import Hummingbird
import Logging

/// The eval: run the replay over the owner's labels, read the latest report, accept its floors.
struct EvalRoutes: Sendable {
    let eval: EvalService

    struct FloorsResponse: Codable {
        let floors: [String: Double]
    }

    func addRoutes(to api: RouterGroup<BasicRequestContext>) {
        let group = api.group("admin").group("eval")

        // GET /admin/eval: the latest report, or 404 before the first run.
        group.get("") { _, _ in
            guard let report = try await self.eval.latest() else { throw HTTPError(.notFound, message: "no eval has run yet") }
            return try jsonResponse(report)
        }

        // POST /admin/eval: replay the current policy over the labelled films (no model call).
        group.post("") { _, _ in
            try jsonResponse(try await self.eval.run(trigger: .manual))
        }

        // POST /admin/eval/accept-floors: adopt every suggested floor from the latest report.
        group.post("accept-floors") { _, _ in
            try jsonResponse(FloorsResponse(floors: try await self.eval.acceptSuggestedFloors()))
        }
    }
}
