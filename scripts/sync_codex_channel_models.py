#!/usr/bin/env python3
import json
import os

import pymysql
from pymysql.cursors import DictCursor

MYSQL_HOST = os.environ.get("MYSQL_HOST", "127.0.0.1")
MYSQL_USER = os.environ.get("MYSQL_USER", "root")
MYSQL_PASS = os.environ.get("MYSQL_PASS", "")
MYSQL_DB = os.environ.get("MYSQL_DB", "newapi")

FREE_MODELS = (
    "gpt-5,gpt-5-codex,gpt-5-codex-mini,gpt-5.1,gpt-5.1-codex,"
    "gpt-5.1-codex-max,gpt-5.1-codex-mini,gpt-5.2,gpt-5.2-codex"
)
TEAM_MODELS = "gpt-5.3,gpt-5.3-codex,gpt-5.3-codex-spark,gpt-5.4"


def models_for_plan(plan: str) -> str:
    return TEAM_MODELS if "team" in str(plan).lower() else FREE_MODELS


def decode_key(raw_key):
    if isinstance(raw_key, dict):
        return raw_key
    if not raw_key:
        return {}
    try:
        return json.loads(raw_key)
    except Exception:
        return {}


def main():
    conn = pymysql.connect(
        host=MYSQL_HOST,
        user=MYSQL_USER,
        password=MYSQL_PASS,
        database=MYSQL_DB,
        cursorclass=DictCursor,
    )
    updated = 0
    scanned = 0
    with conn.cursor() as cur:
        cur.execute("SELECT id, name, `key`, models FROM channels WHERE type = 57")
        rows = cur.fetchall() or []
        for row in rows:
            scanned += 1
            token_data = decode_key(row.get("key"))
            plan = str(token_data.get("plan") or "free")
            target_models = models_for_plan(plan)
            if (row.get("models") or "") == target_models:
                continue
            cur.execute("UPDATE channels SET models = %s WHERE id = %s", (target_models, row["id"]))
            updated += 1
            print(f"[sync] channel #{row['id']} {row.get('name','')} -> {plan} -> {target_models}")
    conn.commit()
    conn.close()
    print(f"[sync] scanned={scanned}, updated={updated}")


if __name__ == "__main__":
    main()
