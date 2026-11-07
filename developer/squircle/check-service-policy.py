#!/usr/bin/env python3
"""Exercise the actual pure request policy without UIKit or live diagnostics."""
from pathlib import Path
import subprocess
import sys
import tempfile

source = (Path(sys.argv[1]) / "app/Squircle/Sources/DeveloperEnrollment.swift").read_text()
policy = "enum DeveloperPolicy {" + source.split("enum DeveloperPolicy {", 1)[1].split("\n@MainActor", 1)[0]
checks = r'''
precondition(DeveloperPolicy.allowsServiceRequest("GET", ["v1", "builds"]))
precondition(DeveloperPolicy.allowsServiceRequest("HEAD", ["v1", "builds"]))
precondition(DeveloperPolicy.allowsServiceRequest("POST", ["v1", "builds", "selected", "install-link"]))
precondition(!DeveloperPolicy.allowsServiceRequest("POST", ["v1", "builds"]))
precondition(!DeveloperPolicy.allowsServiceRequest("POST", ["v1", "agents", "restart"]))
precondition(!DeveloperPolicy.allowsServiceRequest("POST", ["v1", "diagnostics"]))
precondition(DeveloperPolicy.allowsServiceRequest("POST", ["v1", "diagnostics"], launchReceipt: true))
precondition(!DeveloperPolicy.allowsServiceRequest("POST", ["v1", "builds"], launchReceipt: true))
precondition(!DeveloperPolicy.allowsServiceRequest("GET", ["v1", "diagnostics"], launchReceipt: true))
precondition(!DeveloperPolicy.allowsServiceRequest("POST", ["v1", "config"], launchReceipt: true))
print("PASS: 10 service-policy cases; no live launch event sent")
'''
with tempfile.TemporaryDirectory(prefix="og-service-policy-") as directory:
    fixture = Path(directory) / "main.swift"
    fixture.write_text(policy + checks)
    subprocess.run(["swift", "-swift-version", "6", str(fixture)], check=True)
