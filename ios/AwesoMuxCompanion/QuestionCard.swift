import SwiftUI

struct QuestionCard: View {
    let control: PendingControl
    let store: CompanionStore
    let context: AnswerContext
    @State private var answers: [String: String] = [:]
    @State private var otherQuestions: Set<String> = []
    @State private var confirmUncertain = false
    private var editable: Bool { store.canAnswer(control, context: context) }
    private var complete: Bool {
        control.questions.allSatisfy { !(answers[$0.id]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Your input", systemImage: "questionmark.circle.fill")
                .font(.caption.weight(.semibold)).foregroundStyle(.tint)
            ForEach(control.questions) { question in
                VStack(alignment: .leading, spacing: 12) {
                    Text(question.question).font(.headline)
                    if let options = question.options {
                        ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                            Button {
                                otherQuestions.remove(question.id); answers[question.id] = option.label
                            } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: answers[question.id] == option.label && !otherQuestions.contains(question.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(.tint)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(option.label).font(.body.weight(.medium)).foregroundStyle(.primary)
                                        Text(option.description).font(.subheadline).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }.padding(12).frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                                    .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                            }.buttonStyle(.plain).disabled(!editable)
                                .accessibilityLabel(option.label + ". " + option.description)
                                .accessibilityAddTraits(answers[question.id] == option.label && !otherQuestions.contains(question.id) ? .isSelected : [])
                                .accessibilityIdentifier("option-" + option.label)
                        }
                        if question.isOther {
                            Toggle("Write another answer", isOn: Binding(get: { otherQuestions.contains(question.id) }, set: { value in
                                if value { otherQuestions.insert(question.id) } else { otherQuestions.remove(question.id) }
                                answers[question.id] = nil
                            })).disabled(!editable)
                        }
                    }
                    if question.options == nil || otherQuestions.contains(question.id) {
                        TextField("Your answer", text: Binding(get: { answers[question.id] ?? "" }, set: { answers[question.id] = $0 }), axis: .vertical)
                            .textFieldStyle(.roundedBorder).disabled(!editable)
                            .accessibilityLabel(question.question)
                    }
                }
            }
            if control.priorAttemptUncertain {
                Text("An earlier answer may already have reached Codex.").font(.subheadline).foregroundStyle(.secondary)
                Toggle("I checked the thread and want to answer again", isOn: $confirmUncertain).disabled(!editable)
            }
            if let submission = store.submissions[control.id] {
                submissionStatus(submission)
            } else if control.status != "pending" {
                Text(control.status == "uncertain" ? "Answer outcome unknown. Check the thread." : "Waiting for this question to resolve.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                Button {
                    let frozenAnswers = answers
                    let frozenConfirmation = confirmUncertain
                    Task { await store.submit(control, context: context, answers: frozenAnswers, confirmUncertain: frozenConfirmation) }
                } label: { Text("Submit answer").frame(maxWidth: .infinity, minHeight: 32) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!editable || !complete || (control.priorAttemptUncertain && !confirmUncertain))
                    .accessibilityIdentifier("submit-answer")
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
        .onChange(of: control.questions) { _, _ in answers.removeAll(); otherQuestions.removeAll(); confirmUncertain = false }
    }
    @ViewBuilder private func submissionStatus(_ submission: Submission) -> some View {
        switch submission.status {
        case .submitting: Label("Sending your answer…", systemImage: "clock").font(.subheadline)
        case .submitted: Label("Sent — waiting for Codex", systemImage: "clock").font(.subheadline)
        case .resolved: Label("Question resolved", systemImage: "checkmark.circle").font(.subheadline)
        case .conflict: Text("This question already has an answer in progress.").font(.subheadline)
        case .uncertain:
            Text("Answer outcome unknown. Check the thread before trying again.").font(.subheadline)
            Button("Check / try again") { Task { await store.retry(control.id, operationID: submission.operation.operationID, context: context) } }
                .buttonStyle(.bordered).disabled(context != store.answerContext || !store.active || !store.isFresh)
            Text("Uses the same answer; it won't create a second submission if the host already received it.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
