"""Demo app, worker part: process the orders that arrive from Kafka.

  Kafka topic "orders" ---> sidecar "from-kafka" ---> /shared/consumed.log ---> this program ---> Redis

For every order it pretends to work for a moment, then counts it in Redis and
remembers the last few. The web page shows those numbers.
"""
import json
import os
import socket
import time

from common import Redis, log

INBOX = os.environ.get("INBOX", "/shared/consumed.log")
WORK_SECONDS = float(os.environ.get("WORK_SECONDS", "0.2"))
POD = socket.gethostname()


def lines(path):
    """Yield lines as they are appended to the file, like `tail -F`."""
    while not os.path.exists(path):
        time.sleep(1)
    with open(path, encoding="utf-8") as handle:
        while True:
            line = handle.readline()
            if line.endswith("\n"):
                yield line.strip()
            else:
                time.sleep(0.5)


def process(order):
    time.sleep(WORK_SECONDS)                      # the "work"
    order["worker"] = POD
    while True:
        try:
            with Redis() as redis:
                redis.command("INCR", "demo:processed")
                redis.command("LPUSH", "demo:recent", json.dumps(order))
                redis.command("LTRIM", "demo:recent", 0, 19)
            return
        except Exception as error:  # noqa: BLE001 - Redis down: keep the order and retry
            log(f"level=error event=redis_unavailable error={error!r} retry_in=5s")
            time.sleep(5)


if __name__ == "__main__":
    log(f"level=info event=start part=worker pod={POD} inbox={INBOX}")
    for line in lines(INBOX):
        if not line:
            continue
        try:
            order = json.loads(line)
        except ValueError:
            log(f"level=warn event=skipped reason=not_json line={line[:80]!r}")
            continue
        process(order)
        log(f"level=info event=order_processed id={order.get('id')} item={order.get('item')} "
            f"user={order.get('user')} pod={POD}")
