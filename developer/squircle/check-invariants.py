#!/usr/bin/env python3
"""Check prepared upstream boundaries; these are source checks, not runtime QA."""
import sys
from pathlib import Path
r = Path(sys.argv[1])
src = r / 'app/Squircle/Sources'
gateway = (src / 'T3Gateway.swift').read_text()
dispatch = gateway.split('func dispatch(_ command: JSONValue)', 1)[1].split('private enum Pictures', 1)[0]
assert dispatch.index('DeveloperPolicy.coordinator') < dispatch.index('persistPictures')
assert '["message.dispatch", "run.interrupt", "runtime-request.respond"]' in dispatch
for field in ['modelSelection', 'runtimeMode']:
    assert f'fields.removeValue(forKey: "{field}")' in dispatch
config = (src / 'AppConfiguration.swift').read_text()
assert 'kSecAttrAccessGroup' not in config
assert 'kSecAttrAccessibleWhenUnlockedThisDeviceOnly' in config
assert 'bundle.url(forResource: "client"' not in config
model = (src / 'SquircleModel.swift').read_text()
mode = model.split('var runtimeMode: T3RuntimeMode', 1)[1].split('func consumeConfig', 1)[0]
assert '.auto' not in mode
assert 'guard id.threadID == DeveloperPolicy.coordinator' in model
assert '.filter { DeveloperPolicy.projects.contains($0.id) }' in model
inject = (r / 'src/overlay.rs').read_text()
assert 'groups.push(shared.into())' not in inject
assert 'overlay::eligible(&request.configuration, request.no_overlay' in (r / 'src/xcode.rs').read_text()
assert 'configuration == "Debug" && !no_overlay && allowed_method(method)' in inject
assert '"approval-required";' in (r / 'src/agents/selection.rs').read_text().split('const AGENT_MODE:', 1)[1].split('\n', 1)[0]
assert 'static let orchestrationProtocol = "2"' in gateway
print('PASS: dispatch scope, no mode/model writes, enrollment storage, no embedded credential load, release injection exclusion, service default')

assert (r / 'src/bin/companion-inject.rs').read_bytes() == (adapter / 'companion-inject.rs').read_bytes(), 'Offline injector is stale or modified'
