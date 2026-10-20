import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import Testing

@testable import NocturneServer

@Suite struct BudgetGuardTests {

    private func seedSpend(_ fluent: Fluent, _ amounts: [Double]) async throws {
        for amount in amounts {
            try await ApiCall(
                runId: nil, decisionId: nil, provider: "anthropic", endpoint: "/v1/messages",
                model: "claude-haiku-5-5", attempt: 1, httpStatus: 200, durationMs: 10,
                unitsJson: "{}", costUsd: amount
            ).save(on: fluent.db())
        }
    }

    @Test func sumsThisMonthOnly() async throws {
        try await withTestFluent { fluent in
            let settings = SettingsStore(db: fluent.db(), logger: Logger(label: "test"))
            try await settings.ensureTable()
            try await seedSpend(fluent, [1.25, 0.75])
            let guardian = BudgetGuard(fluent: fluent, settings: settings)

            #expect(try await guardian.monthToDateSpend() == 2.0)

            // Rows written "now" fall into the previous month when `now` is the first of next month.
            let nextMonth = Calendar.current.date(byAdding: .month, value: 1, to: BudgetGuard.startOfMonth(Date()))!
            #expect(try await guardian.monthToDateSpend(now: nextMonth) == 0)
        }
    }

    @Test func capFromSettingsWithDefaultAndUnlimited() async throws {
        try await withTestFluent { fluent in
            let settings = SettingsStore(db: fluent.db(), logger: Logger(label: "test"))
            try await settings.ensureTable()
            let guardian = BudgetGuard(fluent: fluent, settings: settings)

            #expect(try await guardian.cap() == BudgetGuard.defaultMonthlyCap)
            try await settings.set(BudgetGuard.settingKey, "42.5")
            #expect(try await guardian.cap() == 42.5)
            try await settings.set(BudgetGuard.settingKey, "0")
            #expect(try await guardian.cap() == nil)
            try await settings.set(BudgetGuard.settingKey, "garbage")
            #expect(try await guardian.cap() == BudgetGuard.defaultMonthlyCap)
        }
    }

    @Test func verdictsByTrigger() async throws {
        try await withTestFluent { fluent in
            let settings = SettingsStore(db: fluent.db(), logger: Logger(label: "test"))
            try await settings.ensureTable()
            try await settings.set(BudgetGuard.settingKey, "1.0")
            let guardian = BudgetGuard(fluent: fluent, settings: settings)

            try await seedSpend(fluent, [0.4])
            #expect(try await guardian.allow(.scheduled) == .ok(spent: 0.4, cap: 1.0))

            try await seedSpend(fluent, [0.6])
            #expect(try await guardian.allow(.scheduled) == .paused(spent: 1.0, cap: 1.0))
            #expect(try await guardian.allow(.realtime) == .paused(spent: 1.0, cap: 1.0))
            #expect(try await guardian.allow(.manual) == .warn(spent: 1.0, cap: 1.0))
            #expect(try await guardian.allow(.manual).allowed)
            #expect(!(try await guardian.allow(.realtime).allowed))

            try await settings.set(BudgetGuard.settingKey, "0")
            #expect(try await guardian.allow(.scheduled) == .ok(spent: 1.0, cap: nil))
        }
    }
}
