import json, re, time, base64, secrets, hashlib, os
import urllib.parse, urllib.request
from curl_cffi import requests

email = "49381c8e@lopenai.com"
password = "chatgpt12345"
proxy = os.environ.get("PROXY_URL", "")

AUTH_URL = "https://auth.openai.com/oauth/authorize"
TOKEN_URL = "https://auth.openai.com/oauth/token"
CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
REDIRECT_URI = "http://localhost:1455/auth/callback"
SCOPE = "openid email profile offline_access"

def b64url(raw):
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")

proxies = {"http": proxy, "https": proxy} if proxy else None
s = requests.Session(proxies=proxies, impersonate="chrome")

verifier = secrets.token_urlsafe(64)
challenge = b64url(hashlib.sha256(verifier.encode()).digest())
state = secrets.token_urlsafe(16)

params = {"client_id": CLIENT_ID, "response_type": "code", "redirect_uri": REDIRECT_URI,
          "scope": SCOPE, "state": state, "code_challenge": challenge,
          "code_challenge_method": "S256", "prompt": "login",
          "id_token_add_organizations": "true", "codex_cli_simplified_flow": "true"}
auth_url = f"{AUTH_URL}?{urllib.parse.urlencode(params)}"

print("[1] init session")
for attempt in range(10):
    try:
        s.get(auth_url, timeout=15)
        trace = s.get("https://cloudflare.com/cdn-cgi/trace", timeout=10).text
        loc = re.search(r"^loc=(.+)$", trace, re.MULTILINE)
        loc = loc.group(1) if loc else "?"
        if loc in ("CN","HK","TW","SG"):
            print(f"    节点 {loc}，重试...")
            s = requests.Session(proxies=proxies, impersonate="chrome")
            continue
        print(f"    节点: {loc}")
        break
    except Exception as e:
        print(f"    连接失败({attempt+1}): {e}")
        time.sleep(2)
        s = requests.Session(proxies=proxies, impersonate="chrome")
        s.get(auth_url, timeout=15) if attempt == 9 else None

did = s.cookies.get("oai-did")
print(f"    did={did}")

print("[2] sentinel")
sen = requests.post("https://sentinel.openai.com/backend-api/sentinel/req",
    headers={"origin":"https://sentinel.openai.com","content-type":"text/plain;charset=UTF-8"},
    data=json.dumps({"p":"","id":did,"flow":"authorize_continue"}),
    proxies=proxies, impersonate="chrome", timeout=15)
print(f"    {sen.status_code}")
sentinel = json.dumps({"p":"","t":"","c":sen.json()["token"],"id":did,"flow":"authorize_continue"})

print("[3] submit email")
r = s.post("https://auth.openai.com/api/accounts/authorize/continue",
    headers={"referer":"https://auth.openai.com/log-in","accept":"application/json",
             "content-type":"application/json","openai-sentinel-token":sentinel},
    data=json.dumps({"username":{"value":email,"kind":"email"},"screen_hint":"login"}))
print(f"    {r.status_code}")

print("[4] send OTP")
r = s.post("https://auth.openai.com/api/accounts/passwordless/send-otp",
    headers={"referer":"https://auth.openai.com/log-in/password","accept":"application/json",
             "content-type":"application/json"})
print(f"    {r.status_code}")

print("    等待验证码...")
import urllib.request as ur
def get_mail(url, headers=None):
    req = ur.Request(url, headers=headers or {})
    with ur.urlopen(req) as resp:
        return resp.read().decode()

code = None
for i in range(30):
    time.sleep(3)
    body = get_mail(f"https://mail.chatgpt.org.uk/api/emails?email={email}",
        {"referer":f"https://mail.chatgpt.org.uk/{email}","User-Agent":"Mozilla/5.0","X-API-Key":"gpt-test"})
    data = json.loads(body)
    for em in data["data"]["emails"]:
        if "openai" in em["from_address"]:
            m = re.search(r"(?<!\d)(\d{6})(?!\d)", em.get("subject","") + " " + em.get("html_content",""))
            if m:
                code = m.group(1)
                break
    if code:
        break
    print(f"    轮询 {i+1}/30...")

if not code:
    print("    验证码获取失败!")
    exit(1)
print(f"    code={code}")

print("[5] validate OTP")
r = s.post("https://auth.openai.com/api/accounts/email-otp/validate",
    headers={"referer":"https://auth.openai.com/email-verification","accept":"application/json",
             "content-type":"application/json"},
    data=json.dumps({"code":code}))
print(f"    {r.status_code}")

print("[6] workspace + token")
auth_cookie = s.cookies.get("oai-client-auth-session")
auth_json = json.loads(base64.b64decode(auth_cookie.split(".")[0]))
wid = auth_json["workspaces"][0]["id"]
print(f"    workspace={wid}")

r = s.post("https://auth.openai.com/api/accounts/workspace/select",
    headers={"content-type":"application/json"},
    data=json.dumps({"workspace_id":wid}))
cont = r.json()["continue_url"]

r = s.get(cont, allow_redirects=False, timeout=15)
r = s.get(r.headers["Location"], allow_redirects=False, timeout=15)
r = s.get(r.headers["Location"], allow_redirects=False, timeout=15)
cbk = r.headers["Location"]

parsed = urllib.parse.urlparse(cbk)
qs = urllib.parse.parse_qs(parsed.query)
code = qs["code"][0]

form = urllib.parse.urlencode({"grant_type":"authorization_code","client_id":CLIENT_ID,
    "code":code,"redirect_uri":REDIRECT_URI,"code_verifier":verifier}).encode()
req = urllib.request.Request(TOKEN_URL, data=form, method="POST",
    headers={"Content-Type":"application/x-www-form-urlencoded","Accept":"application/json"})
with urllib.request.urlopen(req, timeout=30) as resp:
    t = json.loads(resp.read())

parts = t["id_token"].split(".")
pad = "=" * ((4-len(parts[1])%4)%4)
claims = json.loads(base64.urlsafe_b64decode(parts[1]+pad))
now = int(time.time())

token = {
    "id_token": t["id_token"],
    "access_token": t["access_token"],
    "refresh_token": t["refresh_token"],
    "account_id": str((claims.get("https://api.openai.com/auth") or {}).get("chatgpt_account_id","")),
    "last_refresh": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now)),
    "email": claims.get("email",""),
    "type": "codex",
    "expired": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now+t.get("expires_in",0))),
}
print("\n" + json.dumps(token, indent=2, ensure_ascii=False))
