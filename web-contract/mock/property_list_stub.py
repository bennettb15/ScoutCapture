#!/usr/bin/env python3

import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse


FIXTURE_PATH = Path(__file__).with_name("fixtures.json")


def load_fixture():
    with FIXTURE_PATH.open("r", encoding="utf-8") as fixture_file:
        return json.load(fixture_file)


def json_response(handler, status_code, payload):
    encoded = json.dumps(payload).encode("utf-8")
    handler.send_response(status_code)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(encoded)))
    handler.end_headers()
    handler.wfile.write(encoded)


class ContractHandler(BaseHTTPRequestHandler):
    server_version = "ScoutCaptureWebContract/0.1"

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/health":
            return json_response(self, 200, {"status": "ok"})

        if parsed.path != "/v1/properties":
            return json_response(
                self,
                404,
                {"error": {"code": "not_found", "message": "Route not found."}},
            )

        fixture = load_fixture()
        authorization = self.headers.get("Authorization", "")
        org_id = self.headers.get("X-Scout-Org-Id")

        if not authorization.startswith("Bearer "):
            return json_response(
                self,
                401,
                {
                    "error": {
                        "code": "missing_bearer_token",
                        "message": "Authorization: Bearer <token> is required.",
                    }
                },
            )

        token = authorization.removeprefix("Bearer ").strip()
        user_id = fixture["tokens"].get(token)
        if not user_id:
            return json_response(
                self,
                401,
                {
                    "error": {
                        "code": "invalid_token",
                        "message": "Bearer token did not resolve to an authenticated user.",
                    }
                },
            )

        if not org_id:
            return json_response(
                self,
                400,
                {
                    "error": {
                        "code": "missing_org_header",
                        "message": "X-Scout-Org-Id header is required.",
                    }
                },
            )

        membership = next(
            (
                row
                for row in fixture["memberships"]
                if row["org_id"] == org_id
                and row["user_id"] == user_id
                and row["deleted_at"] is None
            ),
            None,
        )
        if membership is None:
            return json_response(
                self,
                403,
                {
                    "error": {
                        "code": "org_membership_required",
                        "message": "Authenticated user is not an active member of the requested org.",
                    }
                },
            )

        query = parse_qs(parsed.query)
        limit = 50
        if "limit" in query:
            raw_limit = query["limit"][0]
            try:
                limit = int(raw_limit)
            except ValueError:
                return json_response(
                    self,
                    400,
                    {
                        "error": {
                            "code": "invalid_limit",
                            "message": "limit must be an integer between 1 and 200.",
                        }
                    },
                )
            if limit < 1 or limit > 200:
                return json_response(
                    self,
                    400,
                    {
                        "error": {
                            "code": "invalid_limit",
                            "message": "limit must be an integer between 1 and 200.",
                        }
                    },
                )

        properties = [
            {
                key: value
                for key, value in row.items()
                if key != "deleted_at"
            }
            for row in fixture["properties"]
            if row["org_id"] == org_id and row["deleted_at"] is None
        ][:limit]

        return json_response(
            self,
            200,
            {
                "data": properties,
                "meta": {
                    "org_id": org_id,
                    "count": len(properties),
                    "limit": limit,
                },
            },
        )

    def log_message(self, format, *args):
        return


def main():
    host = os.environ.get("SCOUT_WEB_CONTRACT_HOST", "127.0.0.1")
    port = int(os.environ.get("SCOUT_WEB_CONTRACT_PORT", "8787"))
    server = ThreadingHTTPServer((host, port), ContractHandler)
    print(f"ScoutCapture web contract stub listening on http://{host}:{port}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
