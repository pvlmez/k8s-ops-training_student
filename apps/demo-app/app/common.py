"""Shared helpers for the demo app: settings, Vault files and a tiny Redis client.

Only the Python standard library is used, so the stock python image runs this
code unchanged (it is mounted from a ConfigMap; there is no image to build).
"""
import json
import os
import socket
import sys
import time

REDIS_HOST = os.environ.get("REDIS_HOST", "redis.redis.svc.cluster.local")
REDIS_PORT = int(os.environ.get("REDIS_PORT", "6379"))
# Files written into the pod by the Vault agent (see the pod annotations)
REDIS_PASSWORD_FILE = os.environ.get("REDIS_PASSWORD_FILE", "/vault/secrets/redis-password")
CONFIG_FILE = os.environ.get("CONFIG_FILE", "/vault/secrets/config.json")


def log(message):
    """One line to standard output: Fluent Bit ships it to Loki."""
    print(f"{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} {message}", flush=True)


def read_file(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read().strip()


def vault_config():
    """The secret secret/demo-app/config, read again on every call so that a
    rotated value is picked up without a restart."""
    return json.loads(read_file(CONFIG_FILE))


class Redis:
    """Just enough of the Redis protocol for this app. One connection per use."""

    def __init__(self):
        self.sock = socket.create_connection((REDIS_HOST, REDIS_PORT), timeout=5)
        self.reader = self.sock.makefile("rb")
        self.command("AUTH", read_file(REDIS_PASSWORD_FILE))

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()

    def close(self):
        try:
            self.reader.close()
            self.sock.close()
        except OSError:
            pass

    def command(self, *parts):
        encoded = [str(part).encode("utf-8") for part in parts]
        request = b"*%d\r\n" % len(encoded)
        for part in encoded:
            request += b"$%d\r\n%s\r\n" % (len(part), part)
        self.sock.sendall(request)
        return self._reply()

    def _reply(self):
        line = self.reader.readline()
        if not line:
            raise ConnectionError("Redis closed the connection")
        kind, rest = line[:1], line[1:].rstrip(b"\r\n")
        if kind == b"+":
            return rest.decode()
        if kind == b"-":
            raise RuntimeError(f"Redis error: {rest.decode()}")
        if kind == b":":
            return int(rest)
        if kind == b"$":
            length = int(rest)
            if length < 0:
                return None
            data = self.reader.read(length + 2)[:-2]
            return data.decode("utf-8", "replace")
        if kind == b"*":
            return [self._reply() for _ in range(int(rest))]
        raise RuntimeError(f"unexpected Redis reply: {line!r}")


def redis_ok():
    try:
        with Redis() as redis:
            return redis.command("PING") == "PONG"
    except Exception as error:  # noqa: BLE001 - any failure means "not ready"
        print(f"redis check failed: {error}", file=sys.stderr, flush=True)
        return False
