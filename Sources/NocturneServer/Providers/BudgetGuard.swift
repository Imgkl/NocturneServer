import FluentKit
import Foundation
import HummingbirdFluent
import Logging

/// What started a piece of work. Scheduled and realtime work pauses at the budget cap;
/// manual work warns and proceeds.
enum RunTrigger: String, Sendable, Codable {
    case manual
    case scheduled
    case realtime
}

enum BudgetVerdict: Sendable, Equatable {
    case ok(spent: Double, cap: Double?)
    case warn(spent: Double, cap: Double)
    case paused(spent: Double, cap: Double)

    var allowed: Bool {
        if case .paused = self { return false }
        return true
    }
}

/// Month-to-date spend from `api_calls` against the `budget.monthly_usd` setting.
struct BudgetGuard: Sendable {
    static let settingKey = "budget.monthly_usd"
    static let defaultMonthlyCap: Double = 15

    let fluent: Fluent
    let settings: SettingsStore
    private let logger = Logger(label: "Budget")

    init(fluent: Fluent, settings: SettingsStore) {
        self.fluent = fluent
        self.settings = settings
    }

    /// The configured cap. Unset means the default; zero or negative means unlimited.
    func cap() async throws -> Double? {
        guard let raw = try await settings.get(Self.settingKey), let value = Double(raw) else {
            return Self.defaultMonthlyCap
        }
        return value > 0 ? value : nil
    }

    /// Sum of `api_calls.cost_usd` since the first instant of the current month (local calendar).
    func monthToDateSpend(now: Date = Date()) async throws -> Double {
        let start = Self.startOfMonth(now)
        let rows = try await ApiCall.query(on: fluent.db())
            .filter(\.$createdAt >= start)
            .all()
        return rows.reduce(0) { $0 + $1.costUsd }
    }

    func allow(_ trigger: RunTrigger, now: Date = Date()) async throws -> BudgetVerdict {
        let spent = try await monthToDateSpend(now: now)
        guard let cap = try await cap() else { return .ok(spent: spent, cap: nil) }
        if spent < cap { return .ok(spent: spent, cap: cap) }
        switch trigger {
        case .manual:
            logger.warning("Budget cap reached ($\(spent) of $\(cap)); manual run proceeds")
            return .warn(spent: spent, cap: cap)
        case .scheduled, .realtime:
            logger.warning("Budget cap reached ($\(spent) of $\(cap)); \(trigger.rawValue) work paused")
            return .paused(spent: spent, cap: cap)
        }
    }

    static func startOfMonth(_ date: Date) -> Date {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: components) ?? date
    }
}
