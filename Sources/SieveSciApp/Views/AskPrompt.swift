import SieveSciCore
import SwiftUI

/// The `ask_user` card: one to four questions (single choice, multiple choice, fill-in), each choice
/// question with "Other". Drawn like the permission card — a provisional (dashed) frame, because the
/// answer is still open — with square option marks, keycaps and evidence tags. The core owns the
/// request; this view only renders it and returns an `AskOutcome`.
struct AskPrompt: View {
    let request: AskRequest
    @EnvironmentObject var model: AppModel
    @State private var tab = 0
    @State private var picks: [String: [String]] = [:]
    @State private var otherOn: [String: Bool] = [:]
    @State private var other: [String: String] = [:]
    @State private var text: [String: String] = [:]

    var questions: [AskQuestion] { request.questions }
    var q: AskQuestion { questions[min(tab, questions.count - 1)] }

    func answer(_ q: AskQuestion) -> AskAnswer {
        AskAnswer(questionId: q.id, selected: picks[q.id] ?? [],
                  other: otherOn[q.id] == true ? other[q.id] : nil,
                  text: q.kind == .text ? text[q.id] : nil)
    }
    func answered(_ q: AskQuestion) -> Bool { !answer(q).isEmpty }
    var canSubmit: Bool { questions.allSatisfy { $0.optional || answered($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            header
            if questions.count > 1 { tabs }
            questionBody(q).id(q.id)
            footer
        }
        .padding(Theme.Space.l)
        .padding(.top, Theme.Space.xs)
        .background(Rectangle().fill(Theme.raised))
        .overlay(FrameStroke(provisional: true, color: Theme.accent.opacity(0.7)))
        .overlay(alignment: .topLeading) { LabelTab(text: L("Needs your answer"), tint: Theme.accent).offset(x: Theme.Space.l, y: -8) }
        .padding(.top, 8)
        .appearPop()
        .onChange(of: request.id) { _, _ in tab = 0; picks = [:]; otherOn = [:]; other = [:]; text = [:] }
    }

    var header: some View {
        HStack(spacing: Theme.Space.m) {
            IconBadge(systemName: "questionmark.bubble", tint: Theme.accent, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(questions.count == 1 ? L("SieveSci has a question") : L10n.f("SieveSci has %d questions", questions.count))
                    .font(.system(size: 14, weight: .semibold))
                Text(reasonLine).font(Theme.meta).foregroundStyle(.secondary)
            }
        }
    }

    var reasonLine: String {
        switch q.reason {
        case .direction: return L("Directions found by searching and brainstorming — pick what to pursue.")
        case .missingValue: return L("Something only you can tell it.")
        case .userDecision: return L("A decision that is yours to make.")
        }
    }

    /// Question tabs: header, with a filled square once answered (like a form's completed fields).
    var tabs: some View {
        HStack(spacing: Theme.Space.s) {
            ForEach(Array(questions.enumerated()), id: \.offset) { i, item in
                Button { withAnimation(Theme.Motion.allowed ? Theme.Motion.hover : nil) { tab = i } } label: {
                    HStack(spacing: Theme.Space.xs + 1) {
                        Rectangle().fill(answered(item) ? Theme.accent : .clear).frame(width: 6, height: 6)
                            .overlay(Rectangle().strokeBorder(answered(item) ? Theme.accent : Theme.rule))
                        Text(item.header).font(Theme.label).textCase(.uppercase).tracking(0.6)
                    }
                    .padding(.vertical, 4).padding(.horizontal, 2)
                    .foregroundStyle(i == tab ? .primary : .secondary)
                    .overlay(alignment: .bottom) { Rectangle().fill(i == tab ? Theme.accent : .clear).frame(height: 2) }
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            Text("\(tab + 1)/\(questions.count)").font(Theme.label).monospacedDigit().foregroundStyle(.tertiary)
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    @ViewBuilder func questionBody(_ q: AskQuestion) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs + 2) {
            Text(q.question).font(Theme.bodyStrong).fixedSize(horizontal: false, vertical: true)
            if q.kind == .multi { Text(L("Choose any that apply.")).font(Theme.meta).foregroundStyle(.secondary) }
            if q.kind == .text {
                SpecField(text: Binding(get: { text[q.id] ?? "" }, set: { text[q.id] = $0 }),
                          prompt: q.placeholder ?? L("Type your answer"), multiline: true, onSubmit: advance)
                    .padding(.top, Theme.Space.xs)
            } else {
                ForEach(Array(q.options.enumerated()), id: \.offset) { _, o in optionRow(q, o) }
                if q.allowOther { otherRow(q) }
            }
        }
    }

    func isPicked(_ q: AskQuestion, _ label: String) -> Bool { picks[q.id]?.contains(label) == true }

    func toggle(_ q: AskQuestion, _ label: String) {
        var p = picks[q.id] ?? []
        if q.kind == .multi {
            if let i = p.firstIndex(of: label) { p.remove(at: i) } else { p.append(label) }
        } else {
            p = p == [label] ? [] : [label]
            otherOn[q.id] = false
        }
        picks[q.id] = p
    }

    func optionRow(_ q: AskQuestion, _ o: AskOption) -> some View {
        Button { toggle(q, o.label) } label: {
            HStack(alignment: .top, spacing: Theme.Space.s + 2) {
                Mark(on: isPicked(q, o.label), multi: q.kind == .multi).padding(.top, 3)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Theme.Space.xs + 2) {
                        Text(o.label).font(Theme.bodyStrong).lineLimit(2)
                        if o.recommended { Chip(text: L("Recommended"), tint: Theme.accent) }
                        if let idea = o.idea { Chip(text: idea, tint: .secondary) }
                    }
                    if let d = o.description { Text(d).font(Theme.meta).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    if !o.evidence.isEmpty {
                        HStack(spacing: Theme.Space.xs) {
                            ForEach(o.evidence.prefix(6), id: \.self) { e in
                                Text(e.hasPrefix("@") || e.hasPrefix("r") ? e : "@" + e).font(Theme.monoTiny).foregroundStyle(Theme.accent)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, Theme.Space.xs + 2)
            .background(Rectangle().fill(isPicked(q, o.label) ? Theme.accent.opacity(0.07) : .clear))
        }
        .buttonStyle(HoverRowStyle())
    }

    func otherRow(_ q: AskQuestion) -> some View {
        let on = otherOn[q.id] == true
        return HStack(spacing: Theme.Space.s + 2) {
            Button {
                otherOn[q.id] = !on
                if !on, q.kind == .single { picks[q.id] = [] }
            } label: {
                HStack(spacing: Theme.Space.s + 2) {
                    Mark(on: on, multi: q.kind == .multi)
                    Text(L("Other")).font(Theme.bodyStrong)
                }
            }
            .buttonStyle(.plain)
            SpecField(text: Binding(get: { other[q.id] ?? "" }, set: { v in
                other[q.id] = v
                if !v.isEmpty, otherOn[q.id] != true { otherOn[q.id] = true; if q.kind == .single { picks[q.id] = [] } }
            }), prompt: q.placeholder ?? L("Your own answer"), onSubmit: advance)
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, Theme.Space.xxs)
    }

    var footer: some View {
        HStack(spacing: Theme.Space.s) {
            Text(L("Your answer is recorded in the audit log.")).font(Theme.caption).foregroundStyle(.tertiary)
            Spacer(minLength: Theme.Space.m)
            EqualWidthButtons {
                Button(L("Let's just talk")) { model.answerAsk(.dismissed(nil)) }
                    .buttonStyle(.action)
                    .keyboardShortcut(.cancelAction)
                if questions.count > 1 && tab < questions.count - 1 {
                    Button(L("Next")) { advance() }.buttonStyle(.action)
                }
                Button(L("Submit")) { submit() }
                    .buttonStyle(.primaryAction)
                    .disabled(!canSubmit)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
    }

    func advance() {
        if tab < questions.count - 1 { tab += 1 } else if canSubmit { submit() }
    }

    func submit() {
        model.answerAsk(.answered(questions.map(answer).filter { !$0.isEmpty }))
    }
}

/// Square option mark: a filled square inside a frame (single choice) or a tick box (multiple).
private struct Mark: View {
    let on: Bool
    let multi: Bool
    var body: some View {
        ZStack {
            Rectangle().strokeBorder(on ? Theme.accent : Theme.rule, lineWidth: on ? 1.5 : 1)
            if on {
                if multi {
                    Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(Theme.accent)
                } else {
                    Rectangle().fill(Theme.accent).frame(width: 6, height: 6)
                }
            }
        }
        .frame(width: 12, height: 12)
        .animation(Theme.Motion.allowed ? Theme.Motion.hover : nil, value: on)
    }
}
