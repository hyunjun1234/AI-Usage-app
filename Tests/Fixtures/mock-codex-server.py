#!/usr/bin/env python3
"""Deterministic stdio app-server fixture; never reads real Codex credentials."""

import json
import os
import pathlib
import select
import sys
import time


root = pathlib.Path(__file__).resolve().parent
scenario = json.loads((root / "scenario.json").read_text())["scenario"]
events = root / "events.jsonl"
initialized = False
authenticated = False
reads = 0
logins = 0


def record(event):
    with events.open("a") as stream:
        stream.write(json.dumps(event) + "\n")


def send(message, fragmented=False):
    data = (json.dumps(message, ensure_ascii=False) + "\n").encode("utf-8")
    if fragmented:
        # Split inside a multibyte character as well as inside JSON tokens.
        unicode_offset = data.find("한".encode("utf-8"))
        boundaries = sorted(set([1, 9, len(data) // 2, unicode_offset + 1, len(data)]))
        start = 0
        for end in boundaries:
            if end > start:
                os.write(sys.stdout.fileno(), data[start:end])
                time.sleep(0.01)
                start = end
    else:
        os.write(sys.stdout.fileno(), data)


def reply(request, result=None, error=None, fragmented=False):
    response = {"id": request["id"]}
    response["error" if error is not None else "result"] = error if error is not None else result
    send(response, fragmented)


def auth_error(request):
    reply(request, error={"code": -32000, "message": "Not logged in. Please sign in."})


def limits_result(used_percent):
    return {"rateLimits": {
        "limitId": "codex",
        "planType": "한글 Plus" if scenario == "fragmented" else "plus",
        "primary": {"usedPercent": used_percent, "resetsAt": 1800000000, "windowDurationMins": 300},
        "secondary": {"usedPercent": 42.25, "resetsAt": 1800600000, "windowDurationMins": 10080},
    }}


def next_message():
    # Read exactly one line so select() sees any premature handshake messages.
    line = bytearray()
    while True:
        byte = os.read(sys.stdin.fileno(), 1)
        if not byte:
            return None
        if byte == b"\n":
            return json.loads(line)
        line.extend(byte)


record({"event": "started", "pid": os.getpid()})
while True:
    request = next_message()
    if request is None:
        break
    record(request)
    method = request.get("method")
    if method == "initialize":
        # The client must await this response before initialized or any request.
        if select.select([sys.stdin.fileno()], [], [], 0.15)[0]:
            record({"event": "handshakeViolation"})
            sys.exit(2)
        reply(request, {"userAgent": "mock-codex"})
    elif method == "initialized":
        initialized = True
    elif not initialized:
        record({"event": "handshakeViolation"})
        sys.exit(3)
    elif method == "account/read":
        account = {"type": "chatgpt", "email": "fixture@example.invalid", "planType": "plus"}
        reply(request, {"account": account if authenticated else None, "requiresOpenaiAuth": True})
    elif method == "account/rateLimits/read":
        reads += 1
        if scenario == "auth-error" or (scenario == "login" and not authenticated):
            auth_error(request)
        elif scenario == "login" and reads >= 3:
            authenticated = False
            send({"method": "account/updated", "params": {"authMode": None, "planType": None}})
            auth_error(request)
        elif scenario == "stale-account" and reads == 1:
            send({"method": "account/updated", "params": {"authMode": "chatgpt", "planType": "plus"}})
            # A completed read from the previous account arrives after its account change.
            reply(request, limits_result(91))
        elif scenario == "weekly-primary":
            reply(request, {"rateLimits": {
                "planType": "plus",
                "primary": {"usedPercent": 65.75, "resetsAt": 1800600000, "windowDurationMins": 10080},
                "secondary": None,
            }})
        elif scenario == "reversed-windows":
            reply(request, {"rateLimits": {
                "planType": "plus",
                "primary": {"usedPercent": 65.75, "resetsAt": 1800600000, "windowDurationMins": 10080},
                "secondary": {"usedPercent": 12.5, "resetsAt": 1800000000, "windowDurationMins": 300},
            }})
        elif scenario == "legacy-windows":
            result = limits_result(10.5)
            del result["rateLimits"]["primary"]["windowDurationMins"]
            del result["rateLimits"]["secondary"]["windowDurationMins"]
            reply(request, result)
        else:
            reply(request, limits_result(reads * 10 + 0.5), fragmented=scenario == "fragmented")
    elif method == "account/login/start":
        logins += 1
        if request.get("params", {}).get("type") != "chatgpt":
            reply(request, error={"code": -32602, "message": "Expected ChatGPT login"})
            continue
        if scenario == "retry-login" and logins == 1:
            deadline = time.monotonic() + 2
            while not (root / "release-login").exists() and time.monotonic() < deadline:
                time.sleep(0.01)
        login_id = "fixture-login-" + str(logins) if scenario == "retry-login" else "fixture-login"
        auth_url = "https://auth.openai.com/" + login_id
        if scenario == "invalid-login-url":
            auth_url = "https://auth.openai.com.evil.invalid/fixture-login"
        reply(request, {
            "type": "chatgpt",
            "loginId": login_id,
            "authUrl": auth_url,
        })
        if scenario == "login" or (scenario == "retry-login" and logins == 2):
            time.sleep(0.1)
            authenticated = True
            send({"method": "account/login/completed", "params": {
                "loginId": login_id, "success": True, "error": None,
            }})
        elif scenario == "login-failed":
            time.sleep(0.1)
            send({"method": "account/login/completed", "params": {
                "loginId": login_id, "success": False, "error": "Fixture login failed",
            }})
    elif method == "account/login/cancel":
        reply(request, {"status": "canceled"})
    elif "id" in request:
        reply(request, error={"code": -32601, "message": "Unexpected method: " + str(method)})
