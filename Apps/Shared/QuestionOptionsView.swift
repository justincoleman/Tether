import SwiftUI
import TetherProtocol

/// The options of a question Claude asked, as buttons, plus a field for an
/// answer of your own. Used on the Mac and the phone.
struct QuestionOptionsView: View {
    let question: QuestionPrompt
    let answer: (String) -> Void
    @State private var other = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !question.header.isEmpty {
                Text(question.header)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
            Text(question.question).font(.headline)
            ForEach(question.options, id: \.label) { option in
                Button { answer(option.label) } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(option.label).fontWeight(.medium)
                        if !option.description.isEmpty, option.description != option.label {
                            Text(option.description).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
                }
                .buttonStyle(.bordered)
            }
            HStack {
                TextField("Something else", text: $other)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(sendOther)
                Button("Send", action: sendOther)
                    .disabled(other.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func sendOther() {
        let text = other.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        answer(text)
    }
}
