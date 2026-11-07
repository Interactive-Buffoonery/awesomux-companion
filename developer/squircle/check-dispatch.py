#!/usr/bin/env python3
"""Run actual Swift dispatch/attachment logic against an offline protocol fixture."""
from pathlib import Path
import subprocess
import sys
import tempfile

src = Path(sys.argv[1]) / 'app/Squircle/Sources'
gateway = (src / 'T3Gateway.swift').read_text()
methods = gateway.split('    func dispatch(_ command: JSONValue)', 1)[1].split('    /// `ended`', 1)[0]
policy = 'enum DeveloperPolicy {' + (src / 'DeveloperEnrollment.swift').read_text().split('enum DeveloperPolicy {', 1)[1].split('\n@MainActor', 1)[0]
reduction = (src / 'ClientState/Reduction.swift').read_text()
outcome = 'enum CommandOutcome: Equatable {' + reduction.split('enum CommandOutcome: Equatable {', 1)[1].split('/// A command', 1)[0]
conversion = 'extension CommandOutcome {' + reduction.split('extension CommandOutcome {', 1)[1].split('\nextension CommandOutcome {', 1)[0]
fixture = r'''
enum Reply { case exit(JSONValue), notSent, lost(any Error), cancelled }
@MainActor final class Fixture {
    var calls: [(String, JSONValue)] = []
    var answer = Reply.exit(["_tag": "Success", "value": ["status": "accepted"]])
    func request(_ method: String, _ value: JSONValue) async -> Reply {
        calls.append((method, value))
        if method == "assets.persistChatAttachments" {
            return .exit(["_tag": "Success", "value": ["attachments": [["id": "persisted"]]]])
        }
        return answer
    }
'''
checks = r'''
}
@main struct Checks {
    @MainActor static func main() async {
        let gateway = Fixture()
        let picture: JSONValue = ["dataUrl": "data:image/png;base64,synthetic"]
        for thread in [DeveloperPolicy.coordinator, "other-thread"] {
            for type in ["message.dispatch", "run.interrupt", "runtime-request.respond", "thread.create", "thread.meta.update", "session.configure"] {
                gateway.calls = []
                let command: JSONValue = ["type": .string(type), "threadId": .string(thread), "commandId": "fixed-command",
                    "runId": "known-run", "requestId": "explicit-request", "answers": ["answer": "chosen"],
                    "decision": "decline", "messageId": "fixed-message", "text": "harmless",
                    "attachments": .array([picture]), "dispatchMode": ["type": "start_immediately"],
                    "modelSelection": ["model": "forbidden-override"], "runtimeMode": "auto"]
                let result = await gateway.dispatch(command)
                if thread == DeveloperPolicy.coordinator && ["message.dispatch", "run.interrupt", "runtime-request.respond"].contains(type) {
                    precondition(gateway.calls.map { $0.0 } == ["assets.persistChatAttachments", "orchestration.dispatchCommand"])
                    let sent = gateway.calls[1].1
                    precondition(sent["modelSelection"] == .null && sent["runtimeMode"] == .null)
                    for field in ["commandId", "threadId", "runId", "requestId", "answers", "decision", "messageId", "text", "dispatchMode"] {
                        precondition(sent[field] == command[field])
                    }
                    precondition(sent["attachments"] == [["id": "persisted"]])
                    guard case .accepted = result else { preconditionFailure("command not accepted") }
                } else {
                    precondition(gateway.calls.isEmpty, "refused command uploaded attachments or dispatched")
                    guard case .refused = result else { preconditionFailure("command escaped policy") }
                }
            }
        }
        let command: JSONValue = ["threadId": .string(DeveloperPolicy.coordinator), "type": "run.interrupt", "runId": "known-run"]
        for answer in [Reply.cancelled, .lost(NSError(domain: "fixture", code: 1))] {
            gateway.answer = answer
            guard case .unknown = await gateway.dispatch(command) else { preconditionFailure("uncertain reply became refusal") }
        }
        gateway.answer = .notSent
        guard case .notSent = await gateway.dispatch(command) else { preconditionFailure("notSent classification") }
        print("PASS: protocol fixture covers dispatch scope, no upload on refusal, stable IDs, explicit answers, no overrides and uncertain outcomes")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='companion-dispatch-') as directory:
    path = Path(directory)
    source = path / 'fixture.swift'
    source.write_text((src / 'Support/JSONValue.swift').read_text() + policy + outcome + conversion + fixture + '    func dispatch(_ command: JSONValue)' + methods + checks)
    subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library', str(source), '-o', str(path / 'fixture')], check=True)
    subprocess.run([str(path / 'fixture')], check=True)
