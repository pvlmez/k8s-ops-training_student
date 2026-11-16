"""Demo app, web part: take orders from logged-in users.

  browser --> this server --login--> Keycloak (realm "platform", client "demo-app")
                  |--- order counter and login sessions ---> Redis
                  |--- one line per order ---> /shared/orders.log ---> sidecar ---> Kafka topic "orders"

The client secret and the greeting come from Vault (file /vault/secrets/config.json),
the Redis password too (/vault/secrets/redis-password).
"""
import html
import json
import os
import secrets
import socket
import time
import urllib.error
import urllib.parse
import urllib.request
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from common import Redis, log, redis_ok, vault_config

APP_URL = os.environ["APP_URL"].rstrip("/")            # http://demo.<ip>.sslip.io
ISSUER = os.environ["KEYCLOAK_REALM_URL"].rstrip("/")  # http://keycloak.<ip>.sslip.io/realms/platform
CLIENT_ID = os.environ.get("OIDC_CLIENT_ID", "demo-app")
OUTBOX = os.environ.get("OUTBOX", "/shared/orders.log")
POD = socket.gethostname()
OIDC = f"{ISSUER}/protocol/openid-connect"

counters = {"http_requests": 0, "orders_placed": 0, "logins": 0, "login_failures": 0}

PAGE = """<!doctype html>
<html><head><meta charset="utf-8"><title>Demo shop</title>
<style>
 body {{ font-family: "Segoe UI", Arial, sans-serif; max-width: 760px; margin: 40px auto; color: #1f2933; }}
 h1 {{ border-bottom: 3px solid #0f6e8c; padding-bottom: 8px; }}
 .box {{ background: #e3f1f5; border-left: 6px solid #0f6e8c; padding: 10px 16px; margin: 14px 0; }}
 table {{ border-collapse: collapse; }} td, th {{ border: 1px solid #d9dee3; padding: 5px 12px; text-align: left; }}
 th {{ background: #e3f1f5; }} .muted {{ color: #5b6672; font-size: 0.9em; }}
 input, button {{ font-size: 1em; padding: 4px 8px; }}
</style></head><body>
<h1>Demo shop</h1>
<div class="box">{greeting}</div>
{who}
<h2>Orders</h2>
<table>
 <tr><th>Placed (counter in Redis)</th><td>{placed}</td></tr>
 <tr><th>Processed (by the worker, from Kafka)</th><td>{processed}</td></tr>
 <tr><th>Waiting</th><td>{waiting}</td></tr>
</table>
<h2>Last processed</h2>
{recent}
<p class="muted">Served by pod {pod}. Greeting and passwords come from Vault; the login from Keycloak.</p>
</body></html>
"""


def http_post_form(url, fields):
    data = urllib.parse.urlencode(fields).encode()
    with urllib.request.urlopen(urllib.request.Request(url, data=data), timeout=10) as reply:
        return json.load(reply)


def http_get_json(url, token):
    request = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(request, timeout=10) as reply:
        return json.load(reply)


def status():
    with Redis() as redis:
        placed = int(redis.command("GET", "demo:orders") or 0)
        processed = int(redis.command("GET", "demo:processed") or 0)
        recent = [json.loads(item) for item in redis.command("LRANGE", "demo:recent", 0, 9)]
    return {"placed": placed, "processed": processed, "waiting": max(placed - processed, 0), "recent": recent}


class Handler(BaseHTTPRequestHandler):
    server_version = "demo-app"

    def log_message(self, *_):   # we write our own log lines
        pass

    # --- small helpers -----------------------------------------------------
    def send(self, code, body="", content_type="text/html; charset=utf-8", headers=None):
        payload = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(payload)

    def redirect(self, location, headers=None):
        self.send(303, "", headers={"Location": location, **(headers or {})})

    def session(self):
        cookie = SimpleCookie(self.headers.get("Cookie", ""))
        if "demo_session" not in cookie:
            return None
        with Redis() as redis:
            raw = redis.command("GET", f"demo:session:{cookie['demo_session'].value}")
        return json.loads(raw) if raw else None

    # --- routes ------------------------------------------------------------
    def do_GET(self):
        counters["http_requests"] += 1
        url = urllib.parse.urlparse(self.path)
        query = urllib.parse.parse_qs(url.query)
        try:
            if url.path == "/healthz":
                self.send(200, "ok\n", "text/plain")
            elif url.path == "/readyz":
                ready = redis_ok()
                self.send(200 if ready else 503, "ready\n" if ready else "redis not reachable\n", "text/plain")
            elif url.path == "/metrics":
                self.metrics()
            elif url.path == "/api/status":
                self.send(200, json.dumps(status()) + "\n", "application/json")
            elif url.path == "/login":
                self.login()
            elif url.path == "/callback":
                self.callback(query)
            elif url.path == "/logout":
                self.redirect("/", {"Set-Cookie": "demo_session=; Path=/; Max-Age=0"})
            elif url.path == "/":
                self.home()
            else:
                self.send(404, "not found\n", "text/plain")
        except Exception as error:  # noqa: BLE001 - report, do not crash the server
            log(f"level=error path={url.path} error={error!r}")
            self.send(500, f"Something went wrong: {html.escape(str(error))}\n", "text/plain")

    def do_POST(self):
        counters["http_requests"] += 1
        try:
            if urllib.parse.urlparse(self.path).path == "/order":
                self.order()
            else:
                self.send(404, "not found\n", "text/plain")
        except Exception as error:  # noqa: BLE001
            log(f"level=error path={self.path} error={error!r}")
            self.send(500, f"Something went wrong: {html.escape(str(error))}\n", "text/plain")

    def home(self):
        user = self.session()
        state = status()
        if user:
            who = (f"<p>Logged in as <b>{html.escape(user['username'])}</b> ({html.escape(user.get('email', ''))}) "
                   f"· <a href='/logout'>log out</a></p>"
                   "<form method='post' action='/order'>Item: <input name='item' value='coffee'> "
                   "<button>Place order</button></form>")
        else:
            who = "<p><a href='/login'>Log in with Keycloak</a> to place an order.</p>"
        rows = "".join(
            f"<tr><td>{o.get('id')}</td><td>{html.escape(str(o.get('item')))}</td>"
            f"<td>{html.escape(str(o.get('user')))}</td><td>{html.escape(str(o.get('worker')))}</td></tr>"
            for o in state["recent"])
        recent = (f"<table><tr><th>Order</th><th>Item</th><th>User</th><th>Processed by</th></tr>{rows}</table>"
                  if rows else "<p class='muted'>Nothing yet.</p>")
        self.send(200, PAGE.format(greeting=html.escape(vault_config().get("greeting", "")), who=who,
                                   placed=state["placed"], processed=state["processed"],
                                   waiting=state["waiting"], recent=recent, pod=POD))

    def login(self):
        """Step 1 of the login: send the browser to Keycloak."""
        state = secrets.token_urlsafe(16)
        with Redis() as redis:
            redis.command("SETEX", f"demo:state:{state}", 300, "1")
        params = urllib.parse.urlencode({
            "client_id": CLIENT_ID, "response_type": "code", "scope": "openid profile email",
            "redirect_uri": f"{APP_URL}/callback", "state": state})
        self.redirect(f"{OIDC}/auth?{params}")

    def callback(self, query):
        """Step 2: Keycloak sent the browser back with a one-time code. Swap it
        for a token (pod to pod, with the client secret from Vault) and ask
        Keycloak who the user is."""
        code, state = query.get("code", [""])[0], query.get("state", [""])[0]
        with Redis() as redis:
            known = redis.command("DEL", f"demo:state:{state}") == 1
        if not code or not known:
            counters["login_failures"] += 1
            log(f"level=warn event=login_failed reason=bad_state_or_no_code error={query.get('error', [''])[0]}")
            self.send(400, "Login failed: no valid code came back from Keycloak.\n", "text/plain")
            return
        try:
            token = http_post_form(f"{OIDC}/token", {
                "grant_type": "authorization_code", "code": code, "redirect_uri": f"{APP_URL}/callback",
                "client_id": CLIENT_ID, "client_secret": vault_config()["oidc_client_secret"]})
            info = http_get_json(f"{OIDC}/userinfo", token["access_token"])
        except urllib.error.HTTPError as error:
            counters["login_failures"] += 1
            log(f"level=error event=login_failed reason=token_exchange status={error.code} "
                f"detail={error.read()[:200]!r}")
            self.send(502, "Login failed: Keycloak refused the code or the client secret.\n", "text/plain")
            return
        user = {"username": info.get("preferred_username", "?"), "email": info.get("email", "")}
        sid = secrets.token_urlsafe(24)
        with Redis() as redis:
            redis.command("SETEX", f"demo:session:{sid}", 3600, json.dumps(user))
        counters["logins"] += 1
        log(f"level=info event=login user={user['username']} pod={POD}")
        self.redirect("/", {"Set-Cookie": f"demo_session={sid}; Path=/; HttpOnly; Max-Age=3600"})

    def order(self):
        user = self.session()
        if not user:
            self.send(401, "Log in first.\n", "text/plain")
            return
        length = int(self.headers.get("Content-Length", "0"))
        form = urllib.parse.parse_qs(self.rfile.read(length).decode())
        item = (form.get("item", ["coffee"])[0] or "coffee")[:40]
        with Redis() as redis:
            order_id = redis.command("INCR", "demo:orders")
        record = {"id": order_id, "item": item, "user": user["username"], "ts": int(time.time())}
        # The sidecar "to-kafka" follows this file and sends each line to Kafka.
        with open(OUTBOX, "a", encoding="utf-8") as outbox:
            outbox.write(json.dumps(record) + "\n")
        counters["orders_placed"] += 1
        log(f"level=info event=order_placed id={order_id} item={item} user={user['username']} pod={POD}")
        self.redirect("/")

    def metrics(self):
        lines = [
            "# HELP demo_http_requests_total HTTP requests handled by this pod.",
            "# TYPE demo_http_requests_total counter",
            f"demo_http_requests_total {counters['http_requests']}",
            "# HELP demo_orders_placed_total Orders accepted by this pod.",
            "# TYPE demo_orders_placed_total counter",
            f"demo_orders_placed_total {counters['orders_placed']}",
            "# HELP demo_logins_total Logins through Keycloak, by result.",
            "# TYPE demo_logins_total counter",
            f'demo_logins_total{{result="ok"}} {counters["logins"]}',
            f'demo_logins_total{{result="failed"}} {counters["login_failures"]}',
        ]
        self.send(200, "\n".join(lines) + "\n", "text/plain; version=0.0.4")


if __name__ == "__main__":
    open(OUTBOX, "a", encoding="utf-8").close()
    log(f"level=info event=start part=web pod={POD} app_url={APP_URL} issuer={ISSUER}")
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
