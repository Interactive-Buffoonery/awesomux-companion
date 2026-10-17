"""Retired unauthenticated live probe; retained name fails closed for old callers.

Use bridge/launch_probe.py, which owns an authenticated disposable server and
verifies its notification settings before any inference. Historical trial
results are in docs/reviews; this entry point never connects or starts a turn.
"""


def main():
    raise SystemExit("Retired live probe. Use python3 bridge/launch_probe.py instead.")


if __name__ == "__main__":
    main()
