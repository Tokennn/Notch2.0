#!/usr/bin/env python3
"""
Create a ClickUp board (space/folder/lists/tasks) from CLICKUP_IMPORT_NOTCH2_0.csv.

Usage example:
  export CLICKUP_TOKEN="pk_xxx"
  python3 scripts/clickup_seed_notch_board.py --create-space
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import sys
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib import error, parse, request

BASE_URL = "https://api.clickup.com/api/v2"

PRIORITY_MAP = {
    "urgent": 1,
    "high": 2,
    "normal": 3,
    "low": 4,
}

DEFAULT_SPACE_FEATURES: dict[str, Any] = {
    "due_dates": {
        "enabled": True,
        "start_date": True,
        "remap_due_dates": True,
        "remap_closed_due_date": False,
    },
    "time_tracking": {"enabled": True},
    "tags": {"enabled": True},
    "time_estimates": {"enabled": True},
    "checklists": {"enabled": True},
    "custom_fields": {"enabled": True},
    "remap_dependencies": {"enabled": True},
    "dependency_warning": {"enabled": True},
    "portfolios": {"enabled": True},
}


def norm(value: str) -> str:
    return " ".join(value.strip().lower().split())


def parse_date_to_ms(value: str) -> int | None:
    raw = value.strip()
    if not raw:
        return None
    dt = datetime.strptime(raw, "%Y-%m-%d").replace(tzinfo=timezone.utc)
    return int(dt.timestamp() * 1000)


class ClickUpClient:
    def __init__(self, token: str, timeout_s: int = 30) -> None:
        self.token = token
        self.timeout_s = timeout_s

    def call(
        self,
        method: str,
        path: str,
        params: dict[str, Any] | None = None,
        body: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        url = f"{BASE_URL}{path}"
        if params:
            url = f"{url}?{parse.urlencode(params, doseq=True)}"

        payload: bytes | None = None
        if body is not None:
            payload = json.dumps(body).encode("utf-8")

        req = request.Request(
            url,
            data=payload,
            method=method,
            headers={
                "Authorization": self.token,
                "Content-Type": "application/json",
            },
        )

        try:
            with request.urlopen(req, timeout=self.timeout_s) as resp:
                content = resp.read().decode("utf-8")
        except error.HTTPError as exc:
            content = exc.read().decode("utf-8", errors="replace")
            raise RuntimeError(
                f"ClickUp API error {exc.code} on {method} {path}: {content}"
            ) from exc
        except error.URLError as exc:
            raise RuntimeError(f"Network error on {method} {path}: {exc}") from exc

        if not content:
            return {}
        try:
            return json.loads(content)
        except json.JSONDecodeError:
            raise RuntimeError(f"Invalid JSON response for {method} {path}: {content}")


def choose_team(client: ClickUpClient, wanted_team_id: str | None) -> dict[str, Any]:
    data = client.call("GET", "/team")
    teams = data.get("teams", [])
    if not teams:
        raise RuntimeError("No ClickUp workspace (team) available for this token.")

    if wanted_team_id:
        for team in teams:
            if str(team.get("id")) == str(wanted_team_id):
                return team
        available = ", ".join(f"{t.get('id')}:{t.get('name')}" for t in teams)
        raise RuntimeError(
            f"CLICKUP_TEAM_ID={wanted_team_id} not found. Available: {available}"
        )

    if len(teams) == 1:
        return teams[0]

    available = ", ".join(f"{t.get('id')}:{t.get('name')}" for t in teams)
    raise RuntimeError(
        "Multiple workspaces found. Set CLICKUP_TEAM_ID or pass --team-id. "
        f"Available: {available}"
    )


def find_or_create_space(
    client: ClickUpClient,
    team_id: str,
    space_id: str | None,
    space_name: str,
    create_space: bool,
) -> dict[str, Any]:
    spaces = client.call("GET", f"/team/{team_id}/space", {"archived": "false"}).get(
        "spaces", []
    )

    if space_id:
        for space in spaces:
            if str(space.get("id")) == str(space_id):
                return space
        raise RuntimeError(f"Space id {space_id} not found in team {team_id}.")

    wanted = norm(space_name)
    for space in spaces:
        if norm(str(space.get("name", ""))) == wanted:
            return space

    if not create_space:
        available = ", ".join(f"{s.get('id')}:{s.get('name')}" for s in spaces)
        raise RuntimeError(
            f"Space '{space_name}' not found. Use --create-space, "
            f"or pass --space-id / CLICKUP_SPACE_ID. Available spaces: {available}"
        )

    body = {
        "name": space_name,
        "multiple_assignees": True,
        "features": DEFAULT_SPACE_FEATURES,
    }
    return client.call("POST", f"/team/{team_id}/space", body=body)


def find_or_create_folder(
    client: ClickUpClient, space_id: str, folder_name: str
) -> dict[str, Any]:
    folders = client.call("GET", f"/space/{space_id}/folder", {"archived": "false"}).get(
        "folders", []
    )
    wanted = norm(folder_name)
    for folder in folders:
        if norm(str(folder.get("name", ""))) == wanted:
            return folder
    return client.call("POST", f"/space/{space_id}/folder", body={"name": folder_name})


def get_lists_in_folder(client: ClickUpClient, folder_id: str) -> list[dict[str, Any]]:
    return client.call("GET", f"/folder/{folder_id}/list", {"archived": "false"}).get(
        "lists", []
    )


def find_or_create_list(
    client: ClickUpClient, folder_id: str, list_name: str
) -> dict[str, Any]:
    lists = get_lists_in_folder(client, folder_id)
    wanted = norm(list_name)
    for lst in lists:
        if norm(str(lst.get("name", ""))) == wanted:
            return lst
    return client.call("POST", f"/folder/{folder_id}/list", body={"name": list_name})


def get_existing_task_names(client: ClickUpClient, list_id: str) -> set[str]:
    task_names: set[str] = set()
    page = 0
    while True:
        data = client.call(
            "GET",
            f"/list/{list_id}/task",
            {"archived": "false", "include_closed": "true", "page": page},
        )
        tasks = data.get("tasks", [])
        for task in tasks:
            task_names.add(norm(str(task.get("name", ""))))
        if len(tasks) < 100:
            break
        page += 1
    return task_names


def status_for_list(client: ClickUpClient, list_id: str, wanted_status: str) -> str | None:
    list_data = client.call("GET", f"/list/{list_id}")
    statuses = list_data.get("statuses", [])
    if not statuses:
        return None

    by_norm = {norm(str(s.get("status", ""))): str(s.get("status", "")) for s in statuses}
    found = by_norm.get(norm(wanted_status))
    if found:
        return found

    for st in statuses:
        if str(st.get("type", "")).lower() != "closed":
            return str(st.get("status"))

    return str(statuses[0].get("status"))


def load_rows(csv_path: Path) -> list[dict[str, str]]:
    with csv_path.open("r", encoding="utf-8", newline="") as f:
        reader = csv.DictReader(f)
        rows = [dict(r) for r in reader]
    if not rows:
        raise RuntimeError(f"No data rows found in {csv_path}")
    required = {"List Name", "Task Name", "Description", "Status", "Priority"}
    missing = required - set(rows[0].keys())
    if missing:
        raise RuntimeError(f"CSV is missing columns: {', '.join(sorted(missing))}")
    return rows


def create_task_payload(row: dict[str, str], resolved_status: str | None) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "name": row["Task Name"].strip(),
        "description": row.get("Description", "").strip(),
    }

    if resolved_status:
        payload["status"] = resolved_status

    pr = PRIORITY_MAP.get(norm(row.get("Priority", "")))
    if pr is not None:
        payload["priority"] = pr

    start_ms = parse_date_to_ms(row.get("Start Date", ""))
    if start_ms is not None:
        payload["start_date"] = start_ms
        payload["start_date_time"] = False

    due_ms = parse_date_to_ms(row.get("Due Date", ""))
    if due_ms is not None:
        payload["due_date"] = due_ms
        payload["due_date_time"] = False

    raw_tags = row.get("Tags", "")
    tags = [tag.strip() for tag in raw_tags.split(",") if tag.strip()]
    if tags:
        payload["tags"] = tags

    return payload


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Seed ClickUp board from CLICKUP_IMPORT_NOTCH2_0.csv"
    )
    parser.add_argument(
        "--csv",
        default="CLICKUP_IMPORT_NOTCH2_0.csv",
        help="CSV path with tasks",
    )
    parser.add_argument("--team-id", default=os.getenv("CLICKUP_TEAM_ID"))
    parser.add_argument("--space-id", default=os.getenv("CLICKUP_SPACE_ID"))
    parser.add_argument("--space-name", default="Notch2.0")
    parser.add_argument("--folder-name", default="Roadmap 2026")
    parser.add_argument("--create-space", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    token = os.getenv("CLICKUP_TOKEN") or os.getenv("CLICKUP_API_TOKEN")
    if not token:
        print("Missing CLICKUP_TOKEN (or CLICKUP_API_TOKEN).", file=sys.stderr)
        return 2

    csv_path = Path(args.csv)
    if not csv_path.exists():
        print(f"CSV not found: {csv_path}", file=sys.stderr)
        return 2

    rows = load_rows(csv_path)

    grouped: dict[str, list[dict[str, str]]] = defaultdict(list)
    for row in rows:
        grouped[row["List Name"].strip()].append(row)

    client = ClickUpClient(token=token)

    try:
        user = client.call("GET", "/user")
        username = (
            user.get("user", {}).get("username")
            or user.get("user", {}).get("email")
            or "unknown"
        )
        print(f"[ok] Connected to ClickUp as {username}")

        team = choose_team(client, args.team_id)
        team_id = str(team["id"])
        print(f"[ok] Workspace: {team.get('name')} ({team_id})")

        space = find_or_create_space(
            client=client,
            team_id=team_id,
            space_id=args.space_id,
            space_name=args.space_name,
            create_space=args.create_space,
        )
        space_id = str(space["id"])
        print(f"[ok] Space: {space.get('name')} ({space_id})")

        folder = find_or_create_folder(client, space_id, args.folder_name)
        folder_id = str(folder["id"])
        print(f"[ok] Folder: {folder.get('name')} ({folder_id})")

        list_map: dict[str, dict[str, Any]] = {}
        for list_name in grouped:
            lst = find_or_create_list(client, folder_id, list_name)
            list_map[list_name] = lst
            print(f"[ok] List: {lst.get('name')} ({lst.get('id')})")

        created = 0
        skipped = 0

        for list_name, tasks in grouped.items():
            list_id = str(list_map[list_name]["id"])
            existing_names = get_existing_task_names(client, list_id)

            for row in tasks:
                task_name = row["Task Name"].strip()
                if norm(task_name) in existing_names:
                    skipped += 1
                    if args.verbose:
                        print(f"[skip] {list_name} :: {task_name}")
                    continue

                resolved_status = status_for_list(client, list_id, row.get("Status", ""))
                payload = create_task_payload(row, resolved_status)

                if args.dry_run:
                    created += 1
                    print(f"[dry-run] {list_name} :: {task_name}")
                    continue

                client.call("POST", f"/list/{list_id}/task", body=payload)
                created += 1
                print(f"[new] {list_name} :: {task_name}")

        print(f"[done] Created: {created}, skipped(existing): {skipped}")
        return 0
    except RuntimeError as exc:
        print(f"[error] {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

