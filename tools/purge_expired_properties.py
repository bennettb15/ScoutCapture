#!/usr/bin/env python3
"""Storage-first 30-day property retention. Dry run unless --execute is set."""
import argparse
import datetime as dt
import json
import os
from collections import defaultdict
from urllib.parse import quote, urlencode, urlparse
from urllib.request import Request, urlopen

PROJECT_REF = "chlvazmtucoszicehtnm"
ORIGINALS = "scoutcapture-originals"
SNAPSHOTS = "scoutcapture-session-snapshots"
DELIVERABLES = "scoutcapture-deliverables"
MEDIA_TABLES = (
    ("shots", "storage_bucket", "storage_path"),
    ("session_snapshots", "payload_storage_bucket", "payload_storage_path"),
    ("report_package_files", "storage_bucket", "storage_path"),
    ("temporary_exports", "storage_bucket", "storage_path"),
)


class Client:
    def __init__(self):
        self.base = os.environ["SUPABASE_URL"].rstrip("/")
        self.key = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
        if urlparse(self.base).hostname != f"{PROJECT_REF}.supabase.co":
            raise RuntimeError("Supabase project does not match the expected project")

    def request(self, method, path, payload=None):
        body = None if payload is None else json.dumps(payload).encode()
        request = Request(
            self.base + path, data=body, method=method,
            headers={
                "apikey": self.key,
                "Authorization": f"Bearer {self.key}",
                "Accept": "application/json",
                **({"Content-Type": "application/json"} if body is not None else {}),
            },
        )
        with urlopen(request, timeout=60) as response:
            data = response.read()
        return json.loads(data) if data else None

    def rows(self, table, **filters):
        result = []
        offset = 0
        while True:
            query = urlencode({**filters, "limit": 1000, "offset": offset})
            page = self.request("GET", f"/rest/v1/{table}?{query}")
            if not isinstance(page, list):
                raise RuntimeError(f"Unexpected {table} response")
            result.extend(page)
            if len(page) < 1000:
                return result
            offset += len(page)

    def list_files(self, bucket, folder):
        pending = [folder]
        found = []
        while pending:
            prefix = pending.pop()
            offset = 0
            while True:
                page = self.request(
                    "POST", f"/storage/v1/object/list/{quote(bucket, safe='')}",
                    {"prefix": prefix, "limit": 1000, "offset": offset,
                     "sortBy": {"column": "name", "order": "asc"}},
                )
                if not isinstance(page, list):
                    raise RuntimeError("Unexpected Storage list response")
                for item in page:
                    name = item["name"]
                    path = name if name.startswith(prefix + "/") else prefix + "/" + name
                    if item.get("id") is None:
                        pending.append(path)
                    else:
                        found.append(path)
                if len(page) < 1000:
                    break
                offset += len(page)
                if offset > 200000:
                    raise RuntimeError("Storage folder exceeds safety limit")
        return found

    def remove_files(self, bucket, paths):
        for start in range(0, len(paths), 1000):
            self.request("DELETE", f"/storage/v1/object/{quote(bucket, safe='')}",
                         {"prefixes": paths[start:start + 1000]})

    def preflight_finalizer(self):
        result = self.request("POST", "/rest/v1/rpc/finalize_expired_property_purge",
                              {"target_property_id": "00000000-0000-0000-0000-000000000000"})
        if result is not False:
            raise RuntimeError("Database purge function preflight failed")

    def finalize(self, property_id):
        result = self.request("POST", "/rest/v1/rpc/finalize_expired_property_purge",
                              {"target_property_id": property_id})
        if result is not True:
            raise RuntimeError("Database purge did not return true")


def expired_non_archived(prop, now):
    if prop.get("is_archived") or not prop.get("deleted_at"):
        return False
    deleted = dt.datetime.fromisoformat(prop["deleted_at"].replace("Z", "+00:00"))
    return deleted <= now - dt.timedelta(days=30)


def listed_storage_files(client, org_id, property_id, session_ids):
    files = defaultdict(set)
    for session_id in session_ids:
        files[ORIGINALS].update(client.list_files(ORIGINALS, f"sessions/{session_id}"))
    folder = f"orgs/{org_id}/properties/{property_id}"
    for bucket in (SNAPSHOTS, DELIVERABLES):
        files[bucket].update(client.list_files(bucket, folder))
    return files


def media_manifest(client, prop):
    org_id, property_id = prop["org_id"], prop["id"]
    sessions = client.rows("sessions", select="id", property_id=f"eq.{property_id}")
    session_ids = {row["id"] for row in sessions}
    manifest = defaultdict(set)
    for table, bucket_column, path_column in MEDIA_TABLES:
        fields = [bucket_column, path_column]
        if table == "shots":
            fields += ["session_id", "upload_state"]
        rows = client.rows(table, select=",".join(fields), property_id=f"eq.{property_id}")
        for row in rows:
            path = row.get(path_column)
            bucket = row.get(bucket_column)
            if not path:
                if table == "shots" and row.get("upload_state") == "uploaded":
                    raise RuntimeError("Uploaded shot lacks a Storage path")
                continue
            if table == "shots":
                bucket = bucket or ORIGINALS
                if bucket != ORIGINALS or row["session_id"] not in session_ids or not path.startswith(f"sessions/{row['session_id']}/"):
                    raise RuntimeError("Shot Storage path is outside its session")
            elif bucket not in (SNAPSHOTS, DELIVERABLES) or not path.startswith(f"orgs/{org_id}/properties/{property_id}/"):
                raise RuntimeError("Storage path is outside its property")
            manifest[bucket].add(path)
    for bucket, paths in listed_storage_files(client, org_id, property_id, session_ids).items():
        manifest[bucket].update(paths)
    return {bucket: sorted(paths) for bucket, paths in manifest.items()}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--execute", action="store_true")
    parser.add_argument("--limit", type=int, default=10)
    args = parser.parse_args()
    if args.limit < 1 or args.limit > 100:
        raise SystemExit("--limit must be between 1 and 100")
    client = Client()
    if args.execute:
        client.preflight_finalizer()
    now = dt.datetime.now(dt.timezone.utc)
    cutoff = (now - dt.timedelta(days=30)).isoformat().replace("+00:00", "Z")
    candidates = client.rows("properties", select="id,org_id,is_archived,deleted_at",
                             deleted_at=f"lte.{cutoff}", is_archived="eq.false",
                             order="deleted_at.asc")
    processed = 0
    media_total = 0
    for candidate in candidates[:args.limit]:
        current = client.rows("properties", select="id,org_id,is_archived,deleted_at",
                              id=f"eq.{candidate['id']}")
        if len(current) != 1 or not expired_non_archived(current[0], now):
            continue
        manifest = media_manifest(client, current[0])
        file_count = sum(map(len, manifest.values()))
        if args.execute:
            for bucket, paths in manifest.items():
                client.remove_files(bucket, paths)
            session_ids = {row["id"] for row in client.rows(
                "sessions", select="id", property_id=f"eq.{candidate['id']}")}
            if any(listed_storage_files(client, current[0]["org_id"],
                                        candidate["id"], session_ids).values()):
                raise RuntimeError("Storage still contains files; database rows retained")
            client.finalize(candidate["id"])
        media_total += file_count
        processed += 1
    print(json.dumps({"eligible": len(candidates), "processed": processed,
                      "media_total": media_total,
                      "mode": "execute" if args.execute else "dry_run"}))


if __name__ == "__main__":
    main()
