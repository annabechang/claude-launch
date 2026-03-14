#!/usr/bin/env python3
"""
Refresh the Claude usage cache by calling the Anthropic usage API.

Extracted from statusline.py for use in non-interactive contexts (-p mode).

Usage:
  As module:  from _refresh_usage_cache import refresh_cache
  As CLI:     python3 _refresh_usage_cache.py              # refresh cache
  As CLI:     python3 _refresh_usage_cache.py --print-pct  # print 5h utilization %
"""

import json
import os
import subprocess
import sys
import time

CACHE_FILE = "/tmp/claude-usage-cache.json"
DEFAULT_MAX_AGE = 300  # seconds (5 min to avoid rate limits)


def refresh_cache(max_age=DEFAULT_MAX_AGE):
    """Refresh usage cache from API if stale. Returns parsed data or None.

    If cache is fresh (< max_age seconds old), returns cached data without
    calling the API. Otherwise calls the Anthropic OAuth usage endpoint.
    """
    # Return cached data if fresh enough
    if os.path.exists(CACHE_FILE):
        try:
            age = time.time() - os.path.getmtime(CACHE_FILE)
            if age < max_age:
                with open(CACHE_FILE) as f:
                    return json.load(f)
        except Exception:
            pass

    # Fetch fresh data from API
    try:
        token_json = subprocess.check_output(
            ["security", "find-generic-password",
             "-s", "Claude Code-credentials", "-w"],
            stderr=subprocess.DEVNULL, text=True,
        ).strip()
        token = json.loads(token_json)["claudeAiOauth"]["accessToken"]

        result = subprocess.check_output(
            ["curl", "-s", "--max-time", "5",
             "https://api.anthropic.com/api/oauth/usage",
             "-H", f"Authorization: Bearer {token}",
             "-H", "anthropic-beta: oauth-2025-04-20"],
            stderr=subprocess.DEVNULL, text=True,
        ).strip()
        data = json.loads(result)

        with open(CACHE_FILE, "w") as f:
            json.dump(data, f)
        os.chmod(CACHE_FILE, 0o600)

        return data
    except Exception:
        return None


def main():
    print_pct = "--print-pct" in sys.argv
    data = refresh_cache(max_age=10)  # Force near-fresh for CLI calls

    if data is None:
        if print_pct:
            print("?")
        sys.exit(1)

    if print_pct:
        five = data.get("five_hour", {})
        pct = float(five.get("utilization", 0) or 0)
        print(f"{pct:.0f}")
    sys.exit(0)


if __name__ == "__main__":
    main()
