import Foundation
import SieveSciCore

extension QuotaText {
    static func reset(_ m: QuotaSnapshot.Meter) -> String? {
        guard let r = m.resetsAt else { return nil }
        return L10n.f("resets %@", r.formatted(.relative(presentation: .named).locale(Locale(identifier: L10n.resolved))))
    }
}
