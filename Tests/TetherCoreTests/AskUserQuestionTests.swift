import Foundation
import Testing
@testable import TetherCore
import TetherProtocol

/// The tool input as the PermissionRequest hook delivered it.
private let colorInput = try! JSONDecoder().decode(JSONValue.self, from: Data(
    #"{"questions":[{"header":"Color","multiSelect":false,"options":[{"description":"Red","label":"Red"},{"description":"Blue","label":"Blue"},{"description":"Green","label":"Green"}],"question":"Which color do you prefer?"}]}"#.utf8))

@Suite struct AskUserQuestionTests {
    @Test func singleQuestionBecomesACard() {
        let prompt = AskUserQuestion.prompt(from: colorInput)
        #expect(prompt?.header == "Color")
        #expect(prompt?.question == "Which color do you prefer?")
        #expect(prompt?.options.map(\.label) == ["Red", "Blue", "Green"])
    }

    @Test func multiSelectAndSeveralQuestionsKeepThePermissionCard() {
        let multi = try! JSONDecoder().decode(JSONValue.self, from: Data(
            #"{"questions":[{"header":"h","multiSelect":true,"options":[{"label":"a","description":""}],"question":"q"}]}"#.utf8))
        #expect(AskUserQuestion.prompt(from: multi) == nil)
        let two = try! JSONDecoder().decode(JSONValue.self, from: Data(
            #"{"questions":[{"question":"a","options":[{"label":"x"}]},{"question":"b","options":[{"label":"y"}]}]}"#.utf8))
        #expect(AskUserQuestion.prompt(from: two) == nil)
        #expect(AskUserQuestion.prompt(from: nil) == nil)
    }

    @Test func answerIsAddedKeyedByQuestion() {
        let updated = AskUserQuestion.updatedInput(colorInput, question: "Which color do you prefer?", answer: "Blue")
        #expect(updated["answers"]?["Which color do you prefer?"]?.stringValue == "Blue")
        #expect(updated["questions"] == colorInput["questions"])
    }

    @Test func allowWithInputIsTheHookResponse() throws {
        let updated = AskUserQuestion.updatedInput(colorInput, question: "Which color do you prefer?", answer: "Red")
        let response = HookRouter.response(for: .allowWithInput(updated), suggestions: nil)
        let json = try JSONDecoder().decode(JSONValue.self, from: response.body)
        let decision = json["hookSpecificOutput"]?["decision"]
        #expect(decision?["behavior"]?.stringValue == "allow")
        #expect(decision?["updatedInput"]?["answers"]?["Which color do you prefer?"]?.stringValue == "Red")
    }

    @Test func summaryNamesTheQuestion() {
        let s = PermissionSummary.describe(toolName: AskUserQuestion.toolName, input: colorInput)
        #expect(s.title == "Ask you a question" && s.detail == "Which color do you prefer?")
    }

    @Test func headingUsesTheQuestion() {
        let prompt = AskUserQuestion.prompt(from: colorInput)
        let request = PermissionRequested(id: UUID(), paneId: nil, sessionId: "s", toolName: AskUserQuestion.toolName,
                                          title: "Ask you a question", detail: "q", question: prompt)
        #expect(request.heading == "Which color do you prefer?")
        let data = try! WireCodec.encoder().encode(request)
        #expect(try! WireCodec.decoder().decode(PermissionRequested.self, from: data) == request)
    }
}
