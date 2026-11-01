import Foundation
import SieveSciCore

/// Plan limits and balances in the interface language (the core reports kinds and numbers).
enum QuotaText {
    static func title(_ m: QuotaSnapshot.Meter) -> String {
        switch m.kind {
        case .balance: return L("Balance")
        case .credit: return L("Credit left")
        case .usage: return L("Spent")
        case .fiveHour: return m.detail == "tokens" ? L("5-hour window · tokens") : L("5-hour window")
        case .weekly: return L("Weekly limit")
        case .weeklyModel: return L10n.f("Weekly limit · %@", m.detail ?? "")
        case .window: return m.detail.map { L10n.f("%@ window", $0) } ?? L("Usage window")
        case .tokens: return L("Tokens")
        case .prompts: return m.detail == "tool calls" ? L("Monthly tool calls") : L("Prompts")
        case .rateLimit, .other: return m.label
        }
    }

    static func value(_ m: QuotaSnapshot.Meter) -> String {
        if m.exhausted { return L("limit reached") }
        if let a = m.amount, m.kind == .balance || m.kind == .credit || m.kind == .usage { return a }
        if let u = m.usedFraction { return L10n.f("%d%% left", Int(((1 - u) * 100).rounded())) }
        return m.remaining
    }

    static func reset(_ m: QuotaSnapshot.Meter) -> String? {
        guard let r = m.resetsAt else { return nil }
        return L10n.f("resets %@", r.formatted(.relative(presentation: .named).locale(Locale(identifier: L10n.resolved))))
    }

    /// One line for the provider list, e.g. "5-hour window 63% left · Weekly limit 20% left".
    static func summary(_ q: QuotaSnapshot) -> String? {
        guard !q.meters.isEmpty else { return nil }
        return q.meters.prefix(2).map { title($0) + " " + value($0) }.joined(separator: " · ")
    }
}
