import Foundation

/// Decides where `cache_control` breakpoints go in an Anthropic Messages request.
///
/// Rules (from Anthropic's prompt-caching guidance; also the approach Reasonix takes):
/// - Render order is tools → system → messages, so one breakpoint on the last system block caches
///   tools + system together. It gets the long TTL when configured (1h entries must precede 5m ones).
/// - One rolling breakpoint on the last block of the last message caches the whole conversation;
///   each request reads everything the previous request wrote.
/// - Each breakpoint looks back at most 20 positions for an earlier entry. A run of consecutive
///   tool_use blocks counts as one position, as does a run of tool_result blocks. Long sequential
///   tool loops can exceed that, so intermediate breakpoints are added every `stride` positions
///   walking back from the tail (max 4 breakpoints in total, one of which is the system block).
public struct AnthropicCachePlan: Equatable {
    /// (messageIndex, blockIndex) pairs that receive an ephemeral 5m breakpoint.
    public var messageBreakpoints: [(Int, Int)]
    public var systemTTL: String?

    public static func == (a: Self, b: Self) -> Bool {
        a.systemTTL == b.systemTTL && a.messageBreakpoints.map { "\($0.0):\($0.1)" } == b.messageBreakpoints.map { "\($0.0):\($0.1)" }
    }

    public static func make(messages: [[JSON]], prefixTTL: String, stride: Int = 15, maxBreakpoints: Int = 4) -> AnthropicCachePlan {
        // Positions in render order. Consecutive tool_use (or tool_result) blocks collapse to one.
        var positions: [(Int, Int)] = []
        var lastKind: String?
        for (mi, blocks) in messages.enumerated() {
            for (bi, block) in blocks.enumerated() {
                let kind = block["type"]?.stringValue ?? ""
                if (kind == "tool_use" || kind == "tool_result"), kind == lastKind, !positions.isEmpty {
                    positions[positions.count - 1] = (mi, bi)  // the run's position ends at its last block
                } else {
                    positions.append((mi, bi))
                }
                lastKind = kind
            }
        }
        var bps: [(Int, Int)] = []
        let budget = maxBreakpoints - 1  // one is reserved for the system prefix (it also covers tools)
        var p = positions.count - 1
        while p >= 0 && bps.count < budget {
            let (mi, bi) = positions[p]
            // thinking blocks cannot carry cache_control; step back to the nearest cacheable block.
            if messages[mi][bi]["type"]?.stringValue == "thinking" || messages[mi][bi]["type"]?.stringValue == "redacted_thinking" {
                p -= 1
                continue
            }
            bps.append((mi, bi))
            p -= stride
        }
        return AnthropicCachePlan(messageBreakpoints: bps.reversed(), systemTTL: prefixTTL)
    }
}
