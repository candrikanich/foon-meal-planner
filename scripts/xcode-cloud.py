#!/usr/bin/env python3 -I
"""Reads Foon's Xcode Cloud builds from the App Store Connect API. Read-only: it only sends GET, and each token is
scoped to the one GET it's for, so a leaked token can't change anything even though the key itself could.

  scripts/xcode-cloud.py runs [count]        recent builds
  scripts/xcode-cloud.py show <number>       a build's jobs, issues, and TestFlight state
  scripts/xcode-cloud.py logs <number> <dir> download a build's logs into a new directory

Needs ~/.appstoreconnect/foon.json ({"key_id": ..., "issuer_id": ...}) beside AuthKey_<key_id>.p8. Neither goes in the repo.
"""
import base64
import json
import os
import pathlib
import subprocess
import sys
import time
import urllib.parse

APP_ID = "6827518762"
API = "https://api.appstoreconnect.apple.com"
KEY_DIR = pathlib.Path.home() / ".appstoreconnect"


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def der_to_raw(der):
    """openssl signs in DER; a JWT wants r and s side by side, 32 bytes each."""
    r_length = der[3]
    r = der[4:4 + r_length]
    s = der[4 + r_length + 2:]
    return r[-32:].rjust(32, b"\0") + s[-32:].rjust(32, b"\0")


def token(scope):
    config = json.loads((KEY_DIR / "foon.json").read_text())
    now = int(time.time())
    header = {"alg": "ES256", "kid": config["key_id"], "typ": "JWT"}
    claims = {"iss": config["issuer_id"], "iat": now, "exp": now + 300, "aud": "appstoreconnect-v1", "scope": [scope]}
    signing = ".".join(b64url(json.dumps(part, separators=(",", ":")).encode()) for part in (header, claims))
    signed = subprocess.run(["openssl", "dgst", "-sha256", "-sign", str(KEY_DIR / f"AuthKey_{config['key_id']}.p8")],
                            input=signing.encode(), capture_output=True, check=True)
    return f"{signing}.{b64url(der_to_raw(signed.stdout))}"


def get(path, **query):
    target = path + ("?" + urllib.parse.urlencode(query, safe="[],-") if query else "")
    # The token goes over stdin, so it never shows in a process list.
    config = f'url = "{API + target}"\nheader = "Authorization: Bearer {token("GET " + target)}"\n'
    done = subprocess.run(["curl", "-sS", "--globoff", "--max-time", "30", "-K", "-"], input=config.encode(), capture_output=True)
    if done.returncode != 0:
        sys.exit(f"Couldn't reach App Store Connect: {done.stderr.decode().strip()}")
    body = json.loads(done.stdout)
    if "errors" in body:
        error = body["errors"][0]
        sys.exit(f"{error.get('status')} on {path}: {error.get('title')}: {error.get('detail')}")
    return body


def product_id():
    return get("/v1/ciProducts", **{"filter[app]": APP_ID})["data"][0]["id"]


def runs(count=5):
    return get(f"/v1/ciProducts/{product_id()}/buildRuns", sort="-number", limit=count)["data"]


def run_numbered(number):
    for run in runs(200):
        if run["attributes"]["number"] == number:
            return run
    sys.exit(f"No build {number} in the latest 200.")


def commit_of(run):
    commit = run["attributes"].get("sourceCommit") or {}
    return (commit.get("commitSha") or "")[:7]


def print_runs(count):
    for run in runs(count):
        a = run["attributes"]
        print(a["number"], a["executionProgress"], a.get("completionStatus") or "-", commit_of(run), a.get("createdDate"))


def show(number):
    run = run_numbered(number)
    a = run["attributes"]
    print(f"Build {number}: {a['executionProgress']} {a.get('completionStatus') or '-'} commit {commit_of(run)}"
          f" started {a.get('startedDate')} finished {a.get('finishedDate')}")
    for action in get(f"/v1/ciBuildRuns/{run['id']}/actions")["data"]:
        b = action["attributes"]
        print(f"  {b['name']}: {b['executionProgress']} {b.get('completionStatus') or '-'} {b.get('issueCounts')}")
        for issue in get(f"/v1/ciBuildActions/{action['id']}/issues", limit=50)["data"]:
            c = issue["attributes"]
            where = c.get("fileSource") or {}
            print(f"    {c['issueType']}: {c['message']} {where.get('path', '')}:{where.get('lineNumber', '')}")
    for build in get(f"/v1/ciBuildRuns/{run['id']}/builds")["data"]:
        # While a build is still running, these can come back without attributes.
        b = build.get("attributes") or {}
        beta = get(f"/v1/builds/{build['id']}/buildBetaDetail")["data"].get("attributes") or {}
        print(f"  App Store Connect build {b.get('version', '?')}: {b.get('processingState', 'not ready')}, internal testing "
              f"{beta.get('internalBuildState', 'not ready')}, expires {b.get('expirationDate')}")


def logs(number, directory):
    run = run_numbered(number)
    target = pathlib.Path(directory)
    target.mkdir(parents=True)
    for action in get(f"/v1/ciBuildRuns/{run['id']}/actions")["data"]:
        for artifact in get(f"/v1/ciBuildActions/{action['id']}/artifacts")["data"]:
            listed = artifact["attributes"]
            if listed["fileType"] not in ("LOG_BUNDLE", "RESULT_BUNDLE"):
                continue
            # The list doesn't carry the download link.
            url = get(f"/v1/ciArtifacts/{artifact['id']}")["data"]["attributes"]["downloadUrl"]
            name = os.path.basename(listed["fileName"])
            file = target / f"{action['attributes']['name']} - {name}"
            subprocess.run(["curl", "-sS", "--fail", "--max-time", "300", "-o", str(file), url], check=True)
            print(file)


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else "runs"
    if command == "runs":
        print_runs(int(sys.argv[2]) if len(sys.argv) > 2 else 5)
    elif command == "show" and len(sys.argv) == 3:
        show(int(sys.argv[2]))
    elif command == "logs" and len(sys.argv) == 4:
        logs(int(sys.argv[2]), sys.argv[3])
    else:
        sys.exit(__doc__)
