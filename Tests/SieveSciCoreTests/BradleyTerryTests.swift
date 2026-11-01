import Foundation
import Testing
@testable import SieveSciCore

/// Deterministic generator so the simulated tournaments are reproducible.
private struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite struct BradleyTerryRanking {
    @Test func recoversTheTrueOrder() {
        var rng = SplitMix(state: 7)
        let truth: [Double] = [2.0, 1.0, 0.0, -1.0, -2.0]      // item 0 strongest
        let pairs = BradleyTerry.schedule(items: 5, comparisons: 200, using: &rng)
        let outcomes = pairs.map { a, b -> (winner: Int, loser: Int) in
            let pa = 1 / (1 + exp(truth[b] - truth[a]))
            return Double.random(in: 0..<1, using: &rng) < pa ? (a, b) : (b, a)
        }
        let s = BradleyTerry.fit(items: 5, outcomes: outcomes)
        #expect(s.sorted { $0.strength > $1.strength }.map(\.index) == [0, 1, 2, 3, 4])
        #expect(abs(s.map(\.strength).reduce(0, +)) < 1e-6, "centred")
        #expect(abs((s[0].strength - s[4].strength) - 4) < 1.2, "the scale is recovered, not just the order")
    }

    @Test func scheduleIsBalancedWithoutRepeatsOrSelfPairs() {
        var rng = SplitMix(state: 1)
        let p = BradleyTerry.schedule(items: 6, comparisons: 15, using: &rng)
        #expect(p.count == 15)
        #expect(p.allSatisfy { $0.0 != $0.1 })
        #expect(Set(p.map { [min($0.0, $0.1), max($0.0, $0.1)] }).count == 15, "all 15 pairs once before any repeat")
        let degrees = (0..<6).map { i in p.filter { $0.0 == i || $0.1 == i }.count }
        #expect(degrees.allSatisfy { $0 == 5 })
        let firsts = (0..<6).map { i in p.filter { $0.0 == i }.count }
        #expect(firsts.max()! < 5, "sides are mixed")
        #expect(BradleyTerry.schedule(items: 1, comparisons: 5, using: &rng).isEmpty)
    }

    @Test func unbeatenAndUnplayedItemsStayFinite() {
        let s = BradleyTerry.fit(items: 3, outcomes: [(0, 1), (0, 1), (0, 1)])
        #expect(s.allSatisfy { $0.strength.isFinite && $0.se.isFinite })
        #expect(s[0].strength > s[2].strength && s[2].strength > s[1].strength, "unplayed item sits between winner and loser")
        #expect(s[2].games == 0)
    }

    @Test func reportMarksInseparableNeighboursAndPositionBias() {
        // 0 and 1 split evenly; both beat 2 every time. Every winner was listed first.
        var outcomes: [(winner: Int, loser: Int)] = []
        for _ in 0..<3 { outcomes += [(0, 1), (1, 0), (0, 2), (1, 2)] }
        let text = DispatchTool.rankReport(items: ["alpha", "beta", "gamma"], outcomes: outcomes, planned: 13, unusable: 1, firstWins: 12, log: "x.jsonl")
        #expect(text.contains("Bradley–Terry"))
        #expect(text.contains("ranks 1–2"))
        #expect(text.contains("1 of 13 comparisons returned no usable verdict"))
        #expect(text.contains("Position bias: the first-listed candidate won 100%"))
        #expect(text.components(separatedBy: "\n")[3].hasSuffix("gamma"))
    }
}
