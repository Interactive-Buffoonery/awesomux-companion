"""Validated, credential-free inputs shared by preparation and personal builds."""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_BUNDLE = "com.interactivebuffoonery.awesomux.companion"
DEFAULT_GROUP = "group." + DEFAULT_BUNDLE


def load(path):
    config = json.loads(Path(path).read_text())
    if set(config) != {"bundle_id", "team_id", "app_group", "project_id", "coordinator"}:
        raise ValueError("config must contain exactly the five example fields; no credentials")
    patterns = {
        "bundle_id": r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+){2,}",
        "app_group": r"group\.[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+){2,}",
        "team_id": r"[A-Z0-9]{10}",
        "project_id": r"[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}",
        "coordinator": r"[A-Za-z0-9][A-Za-z0-9:._-]{0,511}",
    }
    for key, pattern in patterns.items():
        if not isinstance(config[key], str) or not re.fullmatch(pattern, config[key]):
            raise ValueError(f"invalid {key}")
    if not config["app_group"].startswith("group." + config["bundle_id"]):
        raise ValueError("use a dedicated App Group under the personal bundle namespace")
    return config


def substitutions(config):
    return {
        "__COMPANION_BUNDLE__": config["bundle_id"],
        "__COMPANION_KEYCHAIN__": config["bundle_id"] + ".developer.squircle",
        "__COMPANION_PROJECT__": config["project_id"],
        "__COMPANION_COORDINATOR__": config["coordinator"],
    }


def render(text, config):
    for key, value in substitutions(config).items():
        text = text.replace(key, value)
    return text


def personal_spec(config):
    spec = (ROOT / "ios/project.yml").read_text()
    spec = spec.replace(DEFAULT_GROUP, config["app_group"])
    spec = spec.replace(DEFAULT_BUNDLE, config["bundle_id"])
    # The global team setting covers app and widget; no command-line bundle
    # override that would accidentally give both targets the same identifier.
    if spec.count("DEVELOPMENT_TEAM: 7CNK4YPCQX") != 1:
        raise ValueError("project signing settings changed; update the personal generator")
    return spec.replace("DEVELOPMENT_TEAM: 7CNK4YPCQX", "DEVELOPMENT_TEAM: " + config["team_id"])
