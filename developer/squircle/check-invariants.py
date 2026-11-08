#!/usr/bin/env python3
"""Check prepared upstream boundaries; these are source checks, not runtime QA."""
import sys
import subprocess
from configuration import load, render
from pathlib import Path
r = Path(sys.argv[1])
adapter = Path(__file__).resolve().parent
settings = load(r / 'companion-config.json')
assert subprocess.check_output(['git', '-C', str(r), 'rev-parse', 'HEAD'], text=True).strip() == '737f2e881483a4c7237b49d5696adff7d44cad1b'
prepared_patch = subprocess.check_output(['git', '-C', str(r), '-c', 'core.abbrev=7', '-c', 'diff.noprefix=false', '-c', 'diff.mnemonicPrefix=false', 'diff', '--no-color', '--no-ext-diff', '--no-renames', '--binary', '--', '.', ':(exclude)app/Squircle/Squircle.xcodeproj'], text=True).replace(' \n', '\n')
assert prepared_patch == render((adapter / 'integration.patch').read_text(), settings), 'Prepared adapter is stale or modified'
assert (r / 'app/Squircle/Sources/DeveloperEnrollment.swift').read_text() == render((adapter / 'DeveloperEnrollment.swift').read_text(), settings), 'Enrollment is stale or modified' 
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
assert 'guard let id = selectedSessionID, let run = state.activeRunID else { return }' in model
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

assert (r / 'app/Squircle/Overlay/CompanionSquircleNotices.txt').read_text() == "\n\n".join((adapter / name).read_text() for name in ['NOTICE', 'LICENSE', 'LICENSE-OG']), 'Attribution is stale or missing'
