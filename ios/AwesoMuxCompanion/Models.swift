import Foundation

struct ThreadSnapshot: Decodable, Sendable {
    var threadID: String
    var generation: String?
    var connected: Bool
    var updatedAt: Double
    var messages: [ThreadMessage]
    var pending: [PendingControl]
    var operations: [String: String]
    var error: String?
    var unsupportedRequest: Bool
    var capabilities: [String: Bool]
    enum CodingKeys: String, CodingKey {
        case threadID = "thread_id", generation, connected, updatedAt = "updated_at"
        case messages, pending, operations, error, unsupportedRequest = "unsupported_request", capabilities
    }
}

struct ThreadMessage: Decodable, Identifiable, Sendable {
    var itemID: String
    var turnID: String
    var role: String
    var text: String
    var truncated: Bool
    var id: String { turnID + ":" + itemID }
    enum CodingKeys: String, CodingKey { case itemID = "id", turnID = "turn_id", role, text, truncated }
}

struct PendingControl: Decodable, Identifiable, Sendable {
    var id: String
    var questions: [InputQuestion]
    var status: String
    var priorAttemptUncertain: Bool
    var isSupported: Bool {
        !questions.isEmpty && Set(questions.map(\.id)).count == questions.count && questions.allSatisfy { q in
            !q.id.isEmpty && !q.question.isEmpty && !q.isSecret && (q.options == nil || !(q.options?.isEmpty ?? true))
        }
    }
    enum CodingKeys: String, CodingKey { case id = "control_id", questions, status, priorAttemptUncertain = "prior_attempt_uncertain" }
}

struct InputQuestion: Decodable, Identifiable, Hashable, Sendable {
    var id: String
    var header: String
    var question: String
    var options: [InputOption]?
    var isOther: Bool
    var isSecret: Bool
    enum CodingKeys: String, CodingKey { case id, header, question, options, isOther, isSecret }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        header = try c.decode(String.self, forKey: .header)
        question = try c.decode(String.self, forKey: .question)
        options = try c.decodeIfPresent([InputOption].self, forKey: .options)
        isOther = try c.decodeIfPresent(Bool.self, forKey: .isOther) ?? false
        isSecret = try c.decodeIfPresent(Bool.self, forKey: .isSecret) ?? false
    }
}
struct InputOption: Decodable, Hashable, Sendable { var label: String; var description: String }

struct AnswerOperation: Sendable {
    let operationID: String
    let controlID: String
    let generation: String
    let body: Data
    init(control: PendingControl, generation: String, answers: [String: String], confirmUncertain: Bool) throws {
        operationID = UUID().uuidString.lowercased()
        controlID = control.id
        self.generation = generation
        struct Value: Encodable { let answers: [String] }
        struct Payload: Encodable {
            let control_id: String
            let operation_id: String
            let answers: [String: Value]
            let confirm_uncertain: Bool
        }
        body = try JSONEncoder().encode(Payload(control_id: controlID, operation_id: operationID,
            answers: answers.mapValues { Value(answers: [$0.trimmingCharacters(in: .whitespacesAndNewlines)]) },
            confirm_uncertain: confirmUncertain))
    }
}
struct AnswerReply: Sendable { let status: Int; let outcome: String?; let error: String? }
enum SubmissionStatus: Sendable { case submitting, submitted, uncertain, resolved, conflict }
struct Submission: Sendable { let operation: AnswerOperation; var status: SubmissionStatus }
