#!/usr/bin/env python3
"""Seed a local Memos server with the people, Spaces and memos from the design mockups.

Usage: scripts/seed_dev_server.py [http://localhost:5230]

Works with current servers (`memos.api`) and Memos 0.31 (`memos.api.v1`).

Creates `you` (admin, password `memos-dev`) and `mira` (password `memos-dev`), three Spaces,
and a handful of memos. Safe to run against a fresh data directory only.
"""

import json
import sys
import urllib.request
from datetime import datetime, timedelta, timezone

BASE = sys.argv[1] if len(sys.argv) > 1 else "http://localhost:5230"
PASSWORD = "memos-dev"
PACKAGE = "memos.api"
# Request fields Memos 0.31 named differently.
V1_RENAMES = {"MemoService/UpsertMemoReaction": ("parent", "name"), "MemoService/CreateMemoComment": ("parent", "name")}


def call(method: str, body: dict, token: str | None = None) -> dict:
    if PACKAGE == "memos.api.v1" and method in V1_RENAMES:
        old, new = V1_RENAMES[method]
        body = {new if key == old else key: value for key, value in body.items()}
    request = urllib.request.Request(
        f"{BASE}/{PACKAGE}.{method}",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(request) as response:
            return json.loads(response.read() or b"{}")
    except urllib.error.HTTPError as error:
        raise SystemExit(f"{method} failed: {error.code} {error.read().decode()}")


def sign_in(username: str) -> str:
    response = call("AuthService/SignIn", {"passwordCredentials": {"username": username, "password": PASSWORD}})
    return response["accessToken"]


def ago(**delta) -> str:
    return (datetime.now(timezone.utc) - timedelta(**delta)).strftime("%Y-%m-%dT%H:%M:%SZ")


def detect_package() -> str:
    for package in ("memos.api", "memos.api.v1"):
        request = urllib.request.Request(
            f"{BASE}/{package}.InstanceService/GetInstanceProfile", data=b"{}", headers={"Content-Type": "application/json"}, method="POST"
        )
        with urllib.request.urlopen(request) as response:
            if response.headers.get("Content-Type", "").startswith("application/json"):
                return package
    raise SystemExit(f"{BASE} doesn't answer like a Memos server")


def main() -> None:
    global PACKAGE
    PACKAGE = detect_package()
    profile = call("InstanceService/GetInstanceProfile", {})
    if profile.get("needsSetup"):
        call("UserService/CreateUser", {"user": {"username": "you", "displayName": "You", "password": PASSWORD, "role": "ADMIN", "state": "NORMAL"}})
    you = sign_in("you")
    call("UserService/CreateUser", {"user": {"username": "mira", "displayName": "mira", "password": PASSWORD, "role": "USER", "state": "NORMAL"}}, you)
    mira = sign_in("mira")

    spaces = {}
    for space_id, title, emoji in [("personal", "Personal", "🏠"), ("studio", "Studio", "🎨"), ("family", "Family", "🌳")]:
        space = call("SpaceService/CreateSpace", {"space": {"title": title, "icon": {"emoji": emoji}}, "spaceId": space_id}, you)
        spaces[space_id] = space["name"]

    call("SpaceService/CreateSpaceInvitation", {"parent": spaces["studio"], "spaceInvitation": {"invitee": "users/mira", "role": "USER"}}, you)
    call("SpaceService/AcceptSpaceInvitation", {"name": f"{spaces['studio']}/invitations/mira"}, mira)

    memos = [
        (you, "personal", "PRIVATE", ago(days=6, hours=2), "“The details are not the details. They make the design.” Charles Eames #quote"),
        (you, "personal", "PRIVATE", ago(days=5, hours=8), "Repotted the monstera. Two new leaves since spring. #plants"),
        (you, None, "PRIVATE", ago(days=5, hours=2), "Self-hosting note: `memos --port 5230 --data ~/.memos` and back up the SQLite file nightly. #til"),
        (you, "personal", "PRIVATE", ago(days=1, hours=12), "Grocery run after lunch: oat milk, lemons, the good bread, coffee filters. Ask about the pottery class on Saturday."),
        (you, "studio", "PROTECTED", ago(days=1, hours=6), "# Commonplace book\n\nKeep one here. Every quote gets #quote and its source as a link, so the collection becomes searchable by author.\n\n> Read with a pen in hand.\n\n[Commonplace book](https://en.wikipedia.org/wiki/Commonplace_book) #idea"),
        (mira, "studio", "SPACE", ago(days=1, hours=3), "Kiln is free Thursday evening if anyone wants to glaze. #studio"),
        (mira, "studio", "SPACE", ago(days=17), "Lending out my copy of The Design of Everyday Things. The affordance chapter is the one to read if you only read one. #reading"),
        (you, "studio", "SPACE", ago(days=5), "Reading notes on *The Design of Everyday Things*, ch. 3 #reading\n\n- [x] Affordances vs. signifiers\n- [ ] Re-read “knowledge in the head”"),
        (you, "family", "PRIVATE", ago(hours=3), "Morning light over the harbor. Walked the long way to the studio. #walks"),
        (you, "personal", "PRIVATE", ago(hours=2), "## This week\n\n- [ ] Write the 0.27 changelog\n- [ ] Review the Space invitation flow\n- [x] Draft the iOS capture spec #work"),
    ]
    created = []
    for token, space, visibility, create_time, content in memos:
        memo = {"content": content, "visibility": visibility, "state": "NORMAL", "createTime": create_time}
        if space:
            memo["space"] = spaces[space]
        created.append(call("MemoService/CreateMemo", {"memo": memo}, token))

    harbor = next(m for m in created if "harbor" in m["content"])
    call("MemoService/UpdateMemo", {"memo": {"name": harbor["name"], "location": {"placeholder": "Victoria Harbour", "latitude": 22.2855, "longitude": 114.1577}}, "updateMask": "location"}, you)
    commonplace = next(m for m in created if "Commonplace" in m["content"])
    for token, emoji in [(you, "💡"), (mira, "💡"), (mira, "❤️")]:
        call("MemoService/UpsertMemoReaction", {"parent": commonplace["name"], "reaction": {"reactionType": emoji}}, token)
    call("MemoService/CreateMemoComment", {"parent": commonplace["name"], "comment": {"content": "Stealing this. Mine lives in a paper notebook and I can never find anything.", "visibility": "PROTECTED", "state": "NORMAL"}}, mira)

    for title, emoji, memo_filter in [
        ("Reading", "📚", 'tag in ["reading"]'),
        ("Open tasks", "✅", "has_incomplete_tasks"),
        ("Ideas", "💡", 'tag in ["idea"] && pinned'),
    ]:
        call("UserService/CreateMemoView", {"parent": "users/you", "memoView": {"title": title, "filter": memo_filter, "icon": {"emoji": emoji}}}, you)

    print(f"Seeded {len(created)} memos, {len(spaces)} Spaces. Sign in as you / {PASSWORD}.")


if __name__ == "__main__":
    main()
