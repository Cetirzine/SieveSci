import Foundation

/// Pairwise-comparison ranking as in Robin: comparisons are planned (balanced, no repeats until all
/// pairs are used, sides swapped at random) and strengths are fitted with the Bradley–Terry model
/// (minorization–maximization, Hunter 2004) instead of order-dependent Elo updates.
public enum BradleyTerry {
    public struct Score: Sendable, Equatable {
        public var index: Int
        /// Log-strength, centred on 0. P(i beats j) = 1 / (1 + exp(s_j − s_i)).
        public var strength: Double
        /// Approximate standard error of `strength` (observed Fisher information).
        public var se: Double
        public var wins: Int
        public var games: Int
    }

    /// Comparison schedule: each item appears about equally often; no pair repeats until every pair
    /// has been used once; which side is "A" alternates at random so position bias averages out.
    public static func schedule<G: RandomNumberGenerator>(items n: Int, comparisons: Int, using rng: inout G) -> [(Int, Int)] {
        guard n > 1, comparisons > 0 else { return [] }
        var all: [(Int, Int)] = []
        for i in 0..<n { for j in (i + 1)..<n { all.append((i, j)) } }
        var out: [(Int, Int)] = []
        var degree = [Int](repeating: 0, count: n)
        while out.count < comparisons {
            var pool = all.shuffled(using: &rng)
            while !pool.isEmpty, out.count < comparisons {
                // Next pair: the one whose items have played least so far.
                let k = pool.indices.min { degree[pool[$0].0] + degree[pool[$0].1] < degree[pool[$1].0] + degree[pool[$1].1] }!
                let (a, b) = pool.remove(at: k)
                degree[a] += 1; degree[b] += 1
                out.append(Bool.random(using: &rng) ? (a, b) : (b, a))
            }
        }
        return out
    }

    /// Fits strengths from (winner, loser) outcomes. A weak prior (one virtual draw against an
    /// average opponent) keeps unbeaten or unplayed items finite.
    public static func fit(items n: Int, outcomes: [(winner: Int, loser: Int)], iterations: Int = 500) -> [Score] {
        guard n > 0 else { return [] }
        var wins = [Double](repeating: 0.5, count: n)          // prior: half a win …
        var games = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        var w = [Int](repeating: 0, count: n), g = [Int](repeating: 0, count: n)
        for o in outcomes where o.winner != o.loser && o.winner < n && o.loser < n {
            wins[o.winner] += 1
            games[o.winner][o.loser] += 1; games[o.loser][o.winner] += 1
            w[o.winner] += 1; g[o.winner] += 1; g[o.loser] += 1
        }
        var p = [Double](repeating: 1, count: n)
        for _ in 0..<iterations {
            var next = p
            var change = 0.0
            for i in 0..<n {
                // … from one game against a virtual opponent of strength 1.
                var denom = 1 / (p[i] + 1)
                for j in 0..<n where games[i][j] > 0 { denom += games[i][j] / (p[i] + p[j]) }
                next[i] = wins[i] / denom
            }
            let gm = exp(next.map { log($0) }.reduce(0, +) / Double(n))
            for i in 0..<n { next[i] /= gm; change = max(change, abs(log(next[i]) - log(p[i]))) }
            p = next
            if change < 1e-9 { break }
        }
        return (0..<n).map { i in
            var info = p[i] / pow(p[i] + 1, 2)
            for j in 0..<n where games[i][j] > 0 { info += games[i][j] * p[i] * p[j] / pow(p[i] + p[j], 2) }
            return Score(index: i, strength: log(p[i]), se: 1 / sqrt(info), wins: w[i], games: g[i])
        }
    }
}
