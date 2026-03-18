#!/usr/bin/env python3
"""
inject.py 鈥?鎶婃敞鍐屾満杈撳嚭鐨?token JSON 娉ㄥ叆鍒?CLIProxyAPI auth 鐩綍 + new-api 娓犻亾
CLIProxyAPI 鐨?codex auth 鏂囦欢鏍煎紡: ~/.cli-proxy-api/codex-<hash>.json
"""
import json
import hashlib
import os
import sys
import glob
import time


AUTH_DIR = os.environ.get("AUTH_DIR", "/auth")

MYSQL_HOST = os.environ.get("MYSQL_HOST", "mysql")
MYSQL_USER = os.environ.get("MYSQL_USER", "root")
MYSQL_PASS = os.environ.get("MYSQL_PASS", "")
MYSQL_DB = os.environ.get("MYSQL_DB", "newapi")

FREE_MODELS = (
    "gpt-5,gpt-5-codex,gpt-5-codex-mini,gpt-5.1,gpt-5.1-codex,"
    "gpt-5.1-codex-max,gpt-5.1-codex-mini,gpt-5.2,gpt-5.2-codex"
)

TEAM_MODELS = "gpt-5.3,gpt-5.3-codex,gpt-5.3-codex-spark,gpt-5.4"


def _models_for_plan(plan: str) -> str:
    if "team" in str(plan).lower():
        return TEAM_MODELS
    return FREE_MODELS


def _get_db():
    import pymysql
    from pymysql.cursors import DictCursor
    return pymysql.connect(
        host=MYSQL_HOST, user=MYSQL_USER, password=MYSQL_PASS,
        database=MYSQL_DB, cursorclass=DictCursor,
    )


def add_channel_to_newapi(token_data: dict) -> bool:
    """鎶?token 浣滀负 type=57 娓犻亾娣诲姞鍒?new-api 鏁版嵁搴撱€?
    濡傛灉璇?email 宸插瓨鍦ㄦ笭閬撳垯鏇存柊 key锛屼笉閲嶅鍒涘缓銆?""
    if not MYSQL_PASS:
        # 娌℃湁閰嶇疆鏁版嵁搴撹繛鎺ワ紝璺宠繃
        return False

    email = token_data.get("email", "")
    plan = token_data.get("plan", "free")
    models = _models_for_plan(plan)
    channel_key = json.dumps(token_data, ensure_ascii=False, separators=(",", ":"))
    channel_name = f"ChatGPT-{str(plan).title()}-{(email.split('@')[0] if '@' in email else email) or 'account'}"

    try:
        conn = _get_db()
        with conn.cursor() as cur:
            # 妫€鏌ユ槸鍚﹀凡瀛樺湪鍚?email 鐨勬笭閬擄紙閫氳繃 name 鎴?key 涓殑 email 鍖归厤锛?
            cur.execute(
                "SELECT id FROM channels WHERE type = 57 AND `key` LIKE %s LIMIT 1",
                (f'%"email":"{email}"%',),
            )
            existing = cur.fetchone()

            if existing:
                # 鏇存柊宸叉湁娓犻亾鐨?key 鍜?models锛堝埛鏂?token + 鎸?plan 鏇存柊妯″瀷锛?
                cur.execute(
                    "UPDATE channels SET `key` = %s, models = %s, status = 1 WHERE id = %s",
                    (channel_key, models, existing["id"]),
                )
                conn.commit()
                print(f"[inject] 宸叉洿鏂?new-api 娓犻亾 #{existing['id']} ({channel_name})")
            else:
                # 鏂板缓娓犻亾
                cur.execute(
                    "INSERT INTO channels (type, name, `key`, models, `group`, base_url, "
                    "status, created_time, weight, auto_ban, priority, param_override, "
                    "status_code_mapping) "
                    "VALUES (%s, %s, %s, %s, %s, %s, %s, UNIX_TIMESTAMP(), %s, %s, %s, %s, %s)",
                    (57, channel_name, channel_key, models, "default,svip",
                     "http://codex-proxy:9006", 1, 1, 1, 0, '{"stream":true}', '{"429":"retry","502":"retry"}'),
                )
                conn.commit()
                print(f"[inject] 宸叉坊鍔?new-api 娓犻亾: {channel_name}")
        conn.close()
        return True
    except Exception as e:
        print(f"[inject] new-api 娓犻亾鎿嶄綔澶辫触: {e}")
        return False


def inject_token(token_file: str) -> bool:
    """璇诲彇娉ㄥ唽鏈鸿緭鍑虹殑 token JSON锛岃浆鎹㈠苟鍐欏叆 CLIProxyAPI auth 鐩綍"""
    try:
        with open(token_file, "r", encoding="utf-8") as f:
            data = json.loads(f.read())
    except Exception as e:
        print(f"[inject] 璇诲彇 {token_file} 澶辫触: {e}")
        return False

    email = data.get("email", "")
    access_token = data.get("access_token", "")
    refresh_token = data.get("refresh_token", "")
    id_token = data.get("id_token", "")
    account_id = data.get("account_id", "")
    expired = data.get("expired", "")

    if not refresh_token:
        print(f"[inject] {token_file} 缂哄皯 refresh_token锛岃烦杩?)
        return False

    # CLIProxyAPI codex auth 鏍煎紡
    auth_data = {
        "id_token": id_token,
        "access_token": access_token,
        "refresh_token": refresh_token,
        "account_id": account_id,
        "last_refresh": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "email": email,
        "type": "codex",
        "expired": expired,
    }

    # 鏂囦欢鍚? codex-<email_hash>.json
    email_hash = hashlib.md5(email.encode()).hexdigest()[:12]
    out_file = os.path.join(AUTH_DIR, f"codex-{email_hash}.json")

    os.makedirs(AUTH_DIR, exist_ok=True)
    with open(out_file, "w", encoding="utf-8") as f:
        json.dump(auth_data, f, ensure_ascii=False, indent=2)

    print(f"[inject] 宸叉敞鍏? {email} -> {out_file}")

    # 鍚屾椂娣诲姞/鏇存柊 new-api 娓犻亾
    add_channel_to_newapi(data)

    return True


def inject_all():
    """鎵弿 output 鐩綍涓嬫墍鏈?token_*.json 骞舵敞鍏?""
    output_dir = os.environ.get("OUTPUT_DIR", "/app/output")
    injected_marker = os.path.join(output_dir, ".injected")

    # 璇诲彇宸叉敞鍏ョ殑鏂囦欢鍒楄〃
    injected_set = set()
    if os.path.exists(injected_marker):
        with open(injected_marker, "r") as f:
            injected_set = set(f.read().strip().split("\n"))

    pattern = os.path.join(output_dir, "token_*.json")
    files = glob.glob(pattern)

    count = 0
    for f in files:
        basename = os.path.basename(f)
        if basename in injected_set:
            continue
        if inject_token(f):
            injected_set.add(basename)
            count += 1

    # 鏇存柊宸叉敞鍏ユ爣璁?
    with open(injected_marker, "w") as f:
        f.write("\n".join(sorted(injected_set)))

    print(f"[inject] 鏈娉ㄥ叆 {count} 涓柊 token锛宎uth 鐩綍鍏?{len(glob.glob(os.path.join(AUTH_DIR, 'codex-*.json')))} 涓嚟鎹?)
    return count


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--watch":
        # 鐩戞帶妯″紡锛氭瘡 30 绉掓壂鎻忎竴娆?
        print("[inject] 鐩戞帶妯″紡鍚姩锛屾瘡 30 绉掓壂鎻忔柊 token...")
        while True:
            inject_all()
            time.sleep(30)
    else:
        inject_all()

