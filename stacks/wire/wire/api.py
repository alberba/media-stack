"""A small JSON client for the apps' HTTP APIs."""

import json
import time
import urllib.error
import urllib.parse
import urllib.request


class ApiError(Exception):
    def __init__(self, method, url, status, body):
        super().__init__(f"{method} {url} -> {status}: {body[:300]}")
        self.status = status


class Client:
    def __init__(self, base, headers=None, timeout=30):
        self.base = base.rstrip("/")
        self.headers = headers or {}
        self.timeout = timeout

    def request(self, method, path, body=None, query=None):
        url = self.base + path
        if query:
            url += "?" + urllib.parse.urlencode(query)
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(url, data=data, method=method, headers={
            "Accept": "application/json",
            **({"Content-Type": "application/json"} if data is not None else {}),
            **self.headers,
        })
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                raw = resp.read().decode()
        except urllib.error.HTTPError as e:
            raise ApiError(method, url, e.code, e.read().decode(errors="replace")) from None
        return json.loads(raw) if raw.strip() else None

    def get(self, path, **query):
        return self.request("GET", path, query=query or None)

    def post(self, path, body=None, **query):
        return self.request("POST", path, body if body is not None else {}, query or None)

    def put(self, path, body):
        return self.request("PUT", path, body)

    def wait(self, path, timeout=600, interval=5, any_answer=False):
        """Waits until GET path answers 2xx (any HTTP answer with any_answer); raises
        TimeoutError naming the URL."""
        deadline = time.monotonic() + timeout
        while True:
            try:
                if any_answer:
                    urllib.request.urlopen(self.base + path, timeout=self.timeout).close()
                else:
                    self.get(path)
                return
            except urllib.error.HTTPError:
                if any_answer:
                    return
            except (ApiError, OSError, ValueError):
                pass
            if time.monotonic() >= deadline:
                raise TimeoutError(f"{self.base}{path} did not answer in {timeout}s")
            time.sleep(interval)
