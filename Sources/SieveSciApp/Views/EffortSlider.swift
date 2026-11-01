import SieveSciCore
import SwiftUI

/// Reasoning effort as a stepped slider (ZCode / Codex style): a square thumb that springs between
/// stops, can be dragged and snaps, with the level's name under it. `nil` is the model's default.
struct EffortSlider: View {
    @Binding var effort: Effort?
    var compact = false

    static let stops: [Effort?] = [nil] + Effort.allCases.map { Optional($0) }
    static func name(_ e: Effort?) -> String { e.map { L($0.rawValue) } ?? L("Model default") }

    @State private var dragX: CGFloat?
    private var index: Int { Self.stops.firstIndex(of: effort) ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            GeometryReader { g in
                let n = CGFloat(Self.stops.count - 1)
                let step = (g.size.width - 18) / max(n, 1)
                let x = dragX ?? CGFloat(index) * step
                ZStack(alignment: .leading) {
                    // Track with a tick per stop; the filled part follows the thumb.
                    Rectangle().fill(Theme.separator).frame(height: 2).padding(.horizontal, 9)
                    Rectangle().fill(Theme.accent).frame(width: x, height: 2).padding(.leading, 9)
                    ForEach(0..<Self.stops.count, id: \.self) { i in
                        Rectangle().fill(CGFloat(i) * step <= x ? Theme.accent : Theme.rule)
                            .frame(width: 2, height: 8).offset(x: 9 + CGFloat(i) * step - 1)
                    }
                    Rectangle().fill(Theme.accent)
                        .frame(width: 18, height: 18)
                        .overlay(Rectangle().strokeBorder(Theme.ink, lineWidth: 1.5))
                        .hardShadow(pressed: dragX != nil, offset: 2)
                        .offset(x: x)
                }
                .frame(height: 24)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in dragX = min(max(0, v.location.x - 9), n * step) }
                    .onEnded { v in
                        let i = Int((min(max(0, v.location.x - 9), n * step) / max(step, 1)).rounded())
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) { effort = Self.stops[i]; dragX = nil }
                    })
            }
            .frame(height: 24)
            if !compact {
                HStack {
                    ForEach(Array(Self.stops.enumerated()), id: \.offset) { i, s in
                        Text(i == 0 ? L("default") : L(s!.rawValue))
                            .font(Theme.label)
                            .foregroundStyle(i == index ? Theme.accent : .secondary)
                        if i < Self.stops.count - 1 { Spacer(minLength: 0) }
                    }
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(L("Reasoning effort"))
        .accessibilityValue(Self.name(effort))
        .accessibilityAdjustableAction { dir in
            let i = dir == .increment ? min(index + 1, Self.stops.count - 1) : max(index - 1, 0)
            withAnimation(Theme.Motion.settle) { effort = Self.stops[i] }
        }
    }
}

/// Signal bars for the effort level (composer button). Bars fill one after another when it changes.
struct EffortBars: View {
    let effort: Effort?
    var level: Int { EffortSlider.stops.firstIndex(of: effort) ?? 0 }
    var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(1..<EffortSlider.stops.count, id: \.self) { i in
                Rectangle().fill(i <= level ? Theme.accent : Theme.rule)
                    .frame(width: 3, height: 3 + CGFloat(i) * 2)
                    .animation(Theme.Motion.allowed ? Theme.Motion.appear.delay(Double(i) * 0.035) : nil, value: level)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Composer control: the bars and the level; click opens the slider.
struct EffortMenu: View {
    @EnvironmentObject var model: AppModel
    @State private var open = false
    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 5) {
                EffortBars(effort: model.config.effort)
                Text(EffortSlider.name(model.config.effort)).font(Theme.monoTiny).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6).frame(height: Theme.Control.icon)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("Reasoning effort"))
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                SectionLabel(L("Reasoning effort"))
                EffortSlider(effort: $model.config.effort)
            }
            .padding(Theme.Space.l)
            .frame(width: 340)
        }
    }
}
