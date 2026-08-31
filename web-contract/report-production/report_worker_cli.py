#!/usr/bin/env python3
"""Manual allowlisted ScoutCapture report package worker.

This is a production-style orchestration wrapper for local/dev validation. It
does not schedule work and it refuses non-local Supabase URLs unless explicit
remote-validation guards are provided.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import io
import importlib.metadata
import json
import os
import pathlib
import platform
import shutil
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from typing import Any


DELIVERABLES_BUCKET = "scoutcapture-deliverables"
RENDERER_VERSION = "phase2c-shadow-reportlab-refinement-1"
MEDIA_PREPARER_VERSION = "phase2a-shadow-media-prep-2-local-date"
STAMPED_ZIP_EXPORT_VERSION = "stamped-zip-export-2-friendly-filename"
ORIGINAL_JPG_PREVIEW_VERSION = "original-jpg-preview-1"
REPORT_CONTRACT_VERSION = "phase1-report-input-1"
PACKAGED_LOGO_SVG = pathlib.Path("web-contract/report-production/assets/ScoutOnlyLogo.svg")
DISABLED_LOGO_PDF = pathlib.Path("web-contract/report-production/assets/ScoutLogoBlue.pdf")
REPORT_TYPE_MAP = {
    "property": "property_report",
    "priority": "flagged_observations",
    "comparison": "flagged_comparison",
}
REQUIRED_RUNTIME_PATHS = [
    pathlib.Path("web-contract/report-input/report_input_phase1.py"),
    pathlib.Path("web-contract/report-media/report_media_phase2a.py"),
    pathlib.Path("web-contract/report-renderer/report_renderer_phase2b.py"),
    pathlib.Path("web-contract/report-production/assets/ScoutOnlyLogo.svg"),
    pathlib.Path("web-contract/shared/scout_report_visuals.py"),
]


class WorkerError(RuntimeError):
    pass


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--session-id", help="Completed ScoutCapture session UUID to process.")
    parser.add_argument(
        "--snapshot-id",
        help="Specific completed sealed session_snapshots.id to process with --session-id.",
    )
    parser.add_argument(
        "--poll-once",
        action="store_true",
        help="Local/dev proof mode: find allowlisted sealed completed snapshots missing a ready package and process them once.",
    )
    parser.add_argument(
        "--poll-dry-run",
        action="store_true",
        help="With --poll-once, discover and classify snapshots without generating PDFs or writing report rows.",
    )
    parser.add_argument(
        "--allow-session-id",
        action="append",
        default=[],
        help="Explicitly allow a session UUID. Must include --session-id.",
    )
    parser.add_argument(
        "--allow-org-property",
        action="append",
        default=[],
        metavar="ORG_ID:PROPERTY_ID",
        help="Explicitly allow sealed completed snapshots for one org/property pair in --poll-once mode.",
    )
    parser.add_argument(
        "--allow-org-id",
        action="append",
        default=[],
        help="Explicitly allow sealed completed snapshots for all properties in one org in --poll-once mode.",
    )
    parser.add_argument(
        "--output-dir",
        default="/private/tmp/scoutcapture-report-worker",
        help="Local worker artifact directory.",
    )
    parser.add_argument(
        "--retention-mode",
        choices=["dry-run", "apply"],
        default="dry-run",
        help="Apply or dry-run latest-2 package retention. Default is dry-run.",
    )
    parser.add_argument(
        "--allow-remote-validation",
        action="store_true",
        help="Permit an explicitly guarded non-local production-validation run.",
    )
    parser.add_argument(
        "--expected-project-ref",
        help="Required with --allow-remote-validation; must match the Supabase project ref in SUPABASE_URL.",
    )
    parser.add_argument("--include-previous", action="store_true", default=True)
    parser.add_argument("--allow-weather-fetch", action="store_true")
    parser.add_argument(
        "--stamped-zip-package-id",
        help="Generate or reuse an on-demand stamped JPG ZIP export for one ready report package.",
    )
    parser.add_argument(
        "--stamped-zip-shot-id",
        action="append",
        default=[],
        help="Limit stamped JPG ZIP export to one selected current shot id. May be repeated.",
    )
    parser.add_argument(
        "--requested-by-user-id",
        help="Optional authenticated user id to record on a temporary export request.",
    )
    parser.add_argument(
        "--stamped-zip-poll-once",
        action="store_true",
        help="Claim and process queued stamped JPG ZIP temporary_exports once.",
    )
    parser.add_argument(
        "--stamped-zip-poll-dry-run",
        action="store_true",
        help="List queued stamped JPG ZIP exports that would be processed without claiming or writing.",
    )
    parser.add_argument(
        "--stamped-zip-limit",
        type=int,
        default=5,
        help="Maximum queued stamped JPG ZIP exports to inspect in --stamped-zip-poll-once mode.",
    )
    parser.add_argument(
        "--runtime-check",
        action="store_true",
        help="Check local worker runtime dependencies and exit before any Supabase access.",
    )
    parser.add_argument(
        "--require-heif",
        action="store_true",
        help="With --runtime-check, fail if HEIC/HEIF decoding is not registered.",
    )
    parser.add_argument(
        "--heic-preview-session-id",
        action="append",
        default=[],
        help="Generate missing display-only JPG previews for one completed HEIC session. May be repeated.",
    )
    parser.add_argument(
        "--heic-preview-max-long-edge",
        type=int,
        default=1800,
        help="Maximum long edge for display-only original JPG previews.",
    )
    parser.add_argument("--pretty", action="store_true")
    return parser.parse_args()


def stable_json(data: Any, pretty: bool = True) -> str:
    if pretty:
        return json.dumps(data, sort_keys=True, indent=2, separators=(",", ": ")) + "\n"
    return json.dumps(data, sort_keys=True, separators=(",", ":")) + "\n"


def sha256_file(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def read_json(path: pathlib.Path) -> Any:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def write_json(path: pathlib.Path, data: Any, pretty: bool = True) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(stable_json(data, pretty), encoding="utf-8")


def safe_iso_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def project_ref_from_supabase_url(url: str) -> str:
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme not in {"http", "https"}:
        raise WorkerError("SUPABASE_URL must be an http(s) URL.")
    host = parsed.hostname or ""
    if host in {"127.0.0.1", "localhost"}:
        return "local"
    suffix = ".supabase.co"
    if not host.endswith(suffix):
        raise WorkerError("Remote SUPABASE_URL must be a supabase.co project URL.")
    project_ref = host[: -len(suffix)]
    if not project_ref:
        raise WorkerError("Could not derive Supabase project ref from SUPABASE_URL.")
    return project_ref


def execution_environment(url: str, args: argparse.Namespace) -> str:
    project_ref = project_ref_from_supabase_url(url)
    if project_ref == "local":
        return "local-dev"

    if not args.allow_remote_validation:
        raise WorkerError("Refusing non-local SUPABASE_URL without --allow-remote-validation.")
    expected_ref = (args.expected_project_ref or "").strip()
    if not expected_ref:
        raise WorkerError("--expected-project-ref is required with --allow-remote-validation.")
    if expected_ref != project_ref:
        raise WorkerError("--expected-project-ref does not match SUPABASE_URL project ref.")
    if not args.allow_session_id and not args.allow_org_property and not args.allow_org_id:
        raise WorkerError("Remote validation requires at least one --allow-session-id, --allow-org-property, or --allow-org-id.")
    if args.session_id and args.session_id.lower() not in allowed_session_ids(args):
        raise WorkerError("Remote validation --session-id must be explicitly included in --allow-session-id.")
    return "remote-validation"


def package_version(name: str) -> str | None:
    try:
        return importlib.metadata.version(name)
    except importlib.metadata.PackageNotFoundError:
        return None


def runtime_check(require_heif: bool = False) -> tuple[bool, dict[str, Any]]:
    repo = pathlib.Path(__file__).resolve().parents[2]
    details: dict[str, Any] = {
        "ok": True,
        "production_ready": True,
        "python_executable": sys.executable,
        "python_version": sys.version,
        "platform": platform.platform(),
        "packages": {},
        "runtime_files": {},
        "pdfinfo": {},
        "heif": {},
        "blocking_gaps": [],
    }

    for relative_path in REQUIRED_RUNTIME_PATHS:
        full_path = repo / relative_path
        exists = full_path.exists()
        details["runtime_files"][str(relative_path)] = {
            "path": str(full_path),
            "exists": exists,
        }
        if not exists:
            details["ok"] = False
            details["production_ready"] = False
            details["blocking_gaps"].append(f"Required runtime file is missing: {full_path}")

    try:
        from PIL import Image, ImageDraw, ImageFont, ImageOps  # noqa: F401

        details["packages"]["Pillow"] = package_version("Pillow")
    except Exception as error:
        details["ok"] = False
        details["production_ready"] = False
        details["blocking_gaps"].append(f"Pillow import failed: {error}")
        Image = None  # type: ignore[assignment]

    try:
        from reportlab.pdfgen import canvas

        details["packages"]["reportlab"] = package_version("reportlab")
    except Exception as error:
        details["ok"] = False
        details["production_ready"] = False
        details["blocking_gaps"].append(f"reportlab import failed: {error}")
        canvas = None  # type: ignore[assignment]

    try:
        from pypdf import PdfReader

        details["packages"]["pypdf"] = package_version("pypdf")
    except Exception as error:
        details["ok"] = False
        details["production_ready"] = False
        details["blocking_gaps"].append(f"pypdf import failed: {error}")
        PdfReader = None  # type: ignore[assignment]

    pdfinfo_path = shutil.which("pdfinfo")
    details["pdfinfo"]["path"] = pdfinfo_path
    if pdfinfo_path:
        try:
            result = subprocess.run([pdfinfo_path, "-v"], text=True, capture_output=True, timeout=10)
            details["pdfinfo"]["version"] = (result.stdout or result.stderr).splitlines()[0] if (result.stdout or result.stderr) else None
        except Exception as error:
            details["production_ready"] = False
            details["blocking_gaps"].append(f"pdfinfo version check failed: {error}")
    else:
        details["ok"] = False
        details["production_ready"] = False
        details["blocking_gaps"].append("pdfinfo was not found on PATH.")

    heif_registered = False
    heif_error = None
    try:
        import pillow_heif

        pillow_heif.register_heif_opener()
        details["packages"]["pillow-heif"] = package_version("pillow-heif")
        heif_registered = True
    except Exception as error:
        details["packages"]["pillow-heif"] = package_version("pillow-heif")
        heif_error = str(error)

    if "Image" in locals() and Image is not None:
        extensions = Image.registered_extensions()
        heif_extensions = sorted(ext for ext, fmt in extensions.items() if ext.lower() in {".heic", ".heif"} or str(fmt).upper() == "HEIF")
        details["heif"] = {
            "pillow_heif_registered": heif_registered,
            "registered_extensions": heif_extensions,
            "error": heif_error,
        }
        if not heif_registered or not any(ext in heif_extensions for ext in [".heic", ".heif"]):
            details["production_ready"] = False
            details["blocking_gaps"].append("HEIC/HEIF decoding is not registered; install pillow-heif/libheif in the worker runtime.")
            if require_heif:
                details["ok"] = False

    if canvas is not None and PdfReader is not None:
        try:
            buffer = io.BytesIO()
            pdf = canvas.Canvas(buffer)
            pdf.drawString(72, 720, "ScoutCapture runtime preflight")
            pdf.showPage()
            pdf.save()
            buffer.seek(0)
            reader = PdfReader(buffer)
            details["pdf_roundtrip_pages"] = len(reader.pages)
        except Exception as error:
            details["ok"] = False
            details["production_ready"] = False
            details["blocking_gaps"].append(f"PDF generation/read roundtrip failed: {error}")

    return bool(details["ok"]), details


class SupabaseServiceClient:
    def __init__(self, url: str, key: str, environment: str) -> None:
        self.url = url.rstrip("/")
        self.key = key
        self.environment = environment

    @classmethod
    def from_env(cls, args: argparse.Namespace) -> "SupabaseServiceClient":
        url = os.environ.get("SUPABASE_URL", "").strip()
        key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "").strip()
        if not url or not key:
            raise WorkerError("SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are required.")
        environment = execution_environment(url, args)
        return cls(url, key, environment)

    def request(
        self,
        method: str,
        url: str,
        body: bytes | None = None,
        headers: dict[str, str] | None = None,
        timeout: int = 60,
    ) -> bytes:
        req = urllib.request.Request(url, data=body, method=method)
        req.add_header("apikey", self.key)
        req.add_header("Authorization", f"Bearer {self.key}")
        for key, value in (headers or {}).items():
            req.add_header(key, value)
        try:
            with urllib.request.urlopen(req, timeout=timeout) as response:
                return response.read()
        except urllib.error.HTTPError as error:
            detail = error.read().decode("utf-8", errors="replace")
            safe_url = url.replace(self.key, "[redacted]")
            raise WorkerError(f"Supabase request failed {method} {safe_url}: {error.code} {detail}") from error

    def select(self, table: str, query: dict[str, str]) -> list[dict[str, Any]]:
        encoded = urllib.parse.urlencode(query, safe="(),.*")
        data = self.request("GET", f"{self.url}/rest/v1/{table}?{encoded}", headers={"Accept": "application/json"})
        value = json.loads(data.decode("utf-8"))
        if not isinstance(value, list):
            raise WorkerError(f"Expected list response from {table}.")
        return value

    def insert(self, table: str, row: dict[str, Any]) -> dict[str, Any]:
        data = json.dumps(row, sort_keys=True, separators=(",", ":")).encode("utf-8")
        value = self.request(
            "POST",
            f"{self.url}/rest/v1/{table}",
            body=data,
            headers={
                "Accept": "application/json",
                "Content-Type": "application/json",
                "Prefer": "return=representation",
            },
        )
        rows = json.loads(value.decode("utf-8"))
        if not rows:
            raise WorkerError(f"Insert into {table} returned no row.")
        return rows[0]

    def patch(self, table: str, query: dict[str, str], row: dict[str, Any]) -> list[dict[str, Any]]:
        encoded = urllib.parse.urlencode(query, safe="(),.*")
        data = json.dumps(row, sort_keys=True, separators=(",", ":")).encode("utf-8")
        value = self.request(
            "PATCH",
            f"{self.url}/rest/v1/{table}?{encoded}",
            body=data,
            headers={
                "Accept": "application/json",
                "Content-Type": "application/json",
                "Prefer": "return=representation",
            },
        )
        return json.loads(value.decode("utf-8"))

    def upload_object(self, bucket: str, path: str, file_path: pathlib.Path, mime_type: str) -> None:
        encoded_path = "/".join(urllib.parse.quote(part) for part in path.split("/"))
        self.request(
            "POST",
            f"{self.url}/storage/v1/object/{urllib.parse.quote(bucket)}/{encoded_path}",
            body=file_path.read_bytes(),
            headers={"Content-Type": mime_type, "x-upsert": "true"},
            timeout=120,
        )

    def download_object(self, bucket: str, path: str) -> bytes:
        encoded_path = "/".join(urllib.parse.quote(part) for part in path.split("/"))
        return self.request("GET", f"{self.url}/storage/v1/object/{urllib.parse.quote(bucket)}/{encoded_path}", headers={"Accept": "*/*"}, timeout=120)

    def object_exists(self, bucket: str, path: str) -> bool:
        encoded_path = "/".join(urllib.parse.quote(part) for part in path.split("/"))
        req = urllib.request.Request(f"{self.url}/storage/v1/object/{urllib.parse.quote(bucket)}/{encoded_path}", method="GET")
        req.add_header("apikey", self.key)
        req.add_header("Authorization", f"Bearer {self.key}")
        req.add_header("Accept", "*/*")
        try:
            with urllib.request.urlopen(req, timeout=30) as response:
                response.read(1)
                return True
        except urllib.error.HTTPError as error:
            detail = error.read().decode("utf-8", errors="replace")
            if error.code == 404 or (error.code == 400 and "not found" in detail.lower()):
                return False
            raise WorkerError(f"Supabase object check failed GET {bucket}/{path}: {error.code} {detail}") from error

    def delete_object(self, bucket: str, path: str) -> None:
        encoded_path = "/".join(urllib.parse.quote(part) for part in path.split("/"))
        self.request("DELETE", f"{self.url}/storage/v1/object/{urllib.parse.quote(bucket)}/{encoded_path}")


def run_step(cmd: list[str], cwd: pathlib.Path, env: dict[str, str]) -> None:
    safe_cmd = [part if "KEY" not in part and "TOKEN" not in part else "[redacted]" for part in cmd]
    print("RUN", " ".join(safe_cmd), file=sys.stderr)
    result = subprocess.run(cmd, cwd=str(cwd), env=env, text=True, capture_output=True)
    if result.returncode != 0:
        raise WorkerError(
            f"Command failed ({result.returncode}): {' '.join(safe_cmd)}\n"
            f"stdout:\n{result.stdout}\n"
            f"stderr:\n{result.stderr}"
        )


def report_date(validation: dict[str, Any]) -> str:
    raw = (validation.get("inputs") or {}).get("session", {}).get("ended_at_utc") or (
        (validation.get("inputs") or {}).get("session", {}).get("started_at_utc")
    )
    if raw:
        try:
            parsed = dt.datetime.fromisoformat(str(raw).replace("Z", "+00:00"))
            return parsed.astimezone(dt.timezone(dt.timedelta(hours=-4))).strftime("%m/%d/%Y")
        except ValueError:
            pass
    return dt.datetime.now().strftime("%m/%d/%Y")


def path_for_pdf(org_id: str, property_id: str, session_id: str, package_id: str, report_type: str) -> str:
    return (
        f"orgs/{org_id.lower()}/properties/{property_id.lower()}/sessions/{session_id.lower()}"
        f"/packages/{package_id.lower()}/pdfs/{report_type}.pdf"
    )


def expected_zip_path(org_id: str, property_id: str, session_id: str, export_id: str) -> str:
    return (
        f"orgs/{org_id.lower()}/properties/{property_id.lower()}/sessions/{session_id.lower()}"
        f"/exports/stamped-jpg/{export_id.lower()}.zip"
    )


def expected_original_jpg_preview_path(org_id: str, property_id: str, session_id: str, shot_id: str) -> str:
    return (
        f"orgs/{org_id.lower()}/properties/{property_id.lower()}/sessions/{session_id.lower()}"
        f"/previews/original-jpg/{shot_id.lower()}.jpg"
    )


def normalized_selected_shot_ids(args: argparse.Namespace) -> list[str]:
    return sorted(
        {
            str(shot_id).strip().lower()
            for shot_id in (args.stamped_zip_shot_id or [])
            if str(shot_id).strip()
        }
    )


def stamped_zip_cache_key(
    package: dict[str, Any],
    snapshot_row: dict[str, Any],
    selected_shot_ids: list[str] | None = None,
) -> str:
    selected_shot_ids = selected_shot_ids or []
    parts = [
        "stamped_jpg_zip",
        str(package["session_id"]).lower(),
        str(package["snapshot_id"]).lower(),
        MEDIA_PREPARER_VERSION,
        STAMPED_ZIP_EXPORT_VERSION,
        str(snapshot_row.get("raw_session_json_sha256") or ""),
        str(snapshot_row.get("snapshot_payload_sha256") or ""),
    ]
    if selected_shot_ids:
        parts.extend(selected_shot_ids)
        return "stamped-jpg-zip-selected:" + sha256_text("|".join(parts))
    return "stamped-jpg-zip:" + sha256_text("|".join(parts))


def export_filename(validation: dict[str, Any], selected: bool = False) -> str:
    session = validation.get("inputs", {}).get("session", {})
    property_name = session.get("property_name") or "ScoutCapture"
    address = session.get("property_address") or ""
    raw_date = session.get("date_of_service") or report_date(validation)
    safe_bits = [sanitize_filename_part(property_name)]
    if address:
        safe_bits.append(sanitize_filename_part(address.split(",")[0]))
    safe_bits.append("Stamped Photos")
    safe_bits.append(sanitize_filename_part(raw_date.replace("/", "-")))
    return " - ".join(bit for bit in safe_bits if bit) + ".zip"


def sanitize_filename_part(value: Any) -> str:
    raw = str(value or "").strip()
    cleaned = "".join("_" if ch in '/\\:*?"<>|' or ord(ch) < 32 else ch for ch in raw)
    return " ".join(cleaned.split()) or "Export"


def package_is_allowlisted(package: dict[str, Any], args: argparse.Namespace) -> bool:
    session_id = str(package.get("session_id") or "").lower()
    org_id = str(package.get("org_id") or "").lower()
    property_id = str(package.get("property_id") or "").lower()
    return session_id in allowed_session_ids(args) or (org_id, property_id) in allowed_org_properties(args)


def get_or_create_package(
    client: SupabaseServiceClient,
    validation: dict[str, Any],
    attempt_started_at: str,
) -> tuple[dict[str, Any], str]:
    session = validation["inputs"]["session"]
    session_id = validation["session_id"]
    snapshot_id = validation["source_snapshot_id"]
    org_id = session["org_id"]
    property_id = session["property_id"]
    idempotency_key = f"pdf-package:{snapshot_id}:{RENDERER_VERSION}"
    existing = client.select(
        "report_packages",
        {
            "select": "*",
            "idempotency_key": f"eq.{idempotency_key}",
            "deleted_at": "is.null",
            "limit": "1",
        },
    )
    if existing:
        package = existing[0]
        rows = client.patch(
            "report_packages",
            {"id": f"eq.{package['id']}"},
            {
                "status": "generating",
                "started_at": attempt_started_at,
                "locked_at": attempt_started_at,
                "locked_by": "manual-local-dev-worker",
                "attempt_count": int(package.get("attempt_count") or 0) + 1,
                "last_error": None,
            },
        )
        return rows[0] if rows else package, "reused"

    row = {
        "org_id": org_id,
        "property_id": property_id,
        "session_id": session_id,
        "snapshot_id": snapshot_id,
        "status": "generating",
        "generation_trigger": "session_completed",
        "idempotency_key": idempotency_key,
        "session_completed_at": session.get("ended_at_utc") or session.get("started_at_utc"),
        "started_at": attempt_started_at,
        "attempt_count": 1,
        "locked_at": attempt_started_at,
        "locked_by": "manual-local-dev-worker",
        "renderer_version": RENDERER_VERSION,
        "report_contract_version": REPORT_CONTRACT_VERSION,
        "media_preparer_version": MEDIA_PREPARER_VERSION,
    }
    return client.insert("report_packages", row), "created"


def snapshot_metadata(client: SupabaseServiceClient, snapshot_id: str) -> dict[str, Any]:
    rows = client.select(
        "session_snapshots",
        {
            "select": "id,raw_session_json_sha256,snapshot_payload_sha256",
            "id": f"eq.{snapshot_id}",
            "deleted_at": "is.null",
            "limit": "1",
        },
    )
    if not rows:
        raise WorkerError(f"Snapshot metadata not found for {snapshot_id}.")
    return rows[0]


def upsert_file_row(
    client: SupabaseServiceClient,
    package: dict[str, Any],
    report_type: str,
    filename: str,
    pdf_path: pathlib.Path,
    pdf_sha256: str,
    page_count: int,
) -> dict[str, Any]:
    storage_path = path_for_pdf(
        package["org_id"],
        package["property_id"],
        package["session_id"],
        package["id"],
        report_type,
    )
    existing = client.select(
        "report_package_files",
        {
            "select": "*",
            "package_id": f"eq.{package['id']}",
            "report_type": f"eq.{report_type}",
            "deleted_at": "is.null",
            "limit": "1",
        },
    )
    row = {
        "package_id": package["id"],
        "org_id": package["org_id"],
        "property_id": package["property_id"],
        "session_id": package["session_id"],
        "snapshot_id": package["snapshot_id"],
        "report_type": report_type,
        "storage_bucket": DELIVERABLES_BUCKET,
        "storage_path": storage_path,
        "filename": filename,
        "mime_type": "application/pdf",
        "byte_size": pdf_path.stat().st_size,
        "sha256": pdf_sha256,
        "page_count": page_count,
        "storage_deleted_at": None,
        "deleted_at": None,
    }
    if existing:
        rows = client.patch("report_package_files", {"id": f"eq.{existing[0]['id']}"}, row)
        return rows[0]
    return client.insert("report_package_files", row)


def select_ready_package(client: SupabaseServiceClient, package_id: str) -> dict[str, Any]:
    rows = client.select(
        "report_packages",
        {
            "select": "*",
            "id": f"eq.{package_id}",
            "status": "eq.ready",
            "deleted_at": "is.null",
            "limit": "1",
        },
    )
    if not rows:
        raise WorkerError(f"Ready report package not found: {package_id}.")
    return rows[0]


def reusable_temporary_export(client: SupabaseServiceClient, cache_key: str) -> dict[str, Any] | None:
    rows = client.select(
        "temporary_exports",
        {
            "select": "*",
            "cache_key": f"eq.{cache_key}",
            "artifact_type": "eq.stamped_jpg_zip",
            "status": "eq.ready",
            "expires_at": f"gt.{safe_iso_now()}",
            "deleted_at": "is.null",
            "order": "requested_at.desc",
            "limit": "1",
        },
    )
    return rows[0] if rows else None


def create_temporary_export(
    client: SupabaseServiceClient,
    package: dict[str, Any],
    cache_key: str,
    requested_by: str | None,
) -> dict[str, Any]:
    existing = client.select(
        "temporary_exports",
        {
            "select": "*",
            "cache_key": f"eq.{cache_key}",
            "status": "in.(queued,generating)",
            "deleted_at": "is.null",
            "order": "requested_at.desc",
            "limit": "1",
        },
    )
    now = safe_iso_now()
    if existing:
        rows = client.patch(
            "temporary_exports",
            {"id": f"eq.{existing[0]['id']}"},
            {
                "status": "generating",
                "attempt_count": int(existing[0].get("attempt_count") or 0) + 1,
                "locked_at": now,
                "locked_by": "manual-remote-validation-worker",
                "last_error": None,
                "requested_by": requested_by,
            },
        )
        return rows[0] if rows else existing[0]

    return client.insert(
        "temporary_exports",
        {
            "org_id": package["org_id"],
            "property_id": package["property_id"],
            "session_id": package["session_id"],
            "snapshot_id": package["snapshot_id"],
            "artifact_type": "stamped_jpg_zip",
            "status": "generating",
            "cache_key": cache_key,
            "requested_by": requested_by,
            "storage_bucket": DELIVERABLES_BUCKET,
            "mime_type": "application/zip",
            "attempt_count": 1,
            "locked_at": now,
            "locked_by": "manual-remote-validation-worker",
        },
    )


def claim_temporary_export(
    client: SupabaseServiceClient,
    export_row: dict[str, Any],
) -> dict[str, Any] | None:
    now = safe_iso_now()
    rows = client.patch(
        "temporary_exports",
        {"id": f"eq.{export_row['id']}", "status": "eq.queued"},
        {
            "status": "generating",
            "attempt_count": int(export_row.get("attempt_count") or 0) + 1,
            "locked_at": now,
            "locked_by": "stamped-zip-poll-worker",
            "last_error": None,
        },
    )
    return rows[0] if rows else None


def zip_prepared_current_media(
    prepared_media_path: pathlib.Path,
    zip_path: pathlib.Path,
    selected_shot_ids: list[str] | None = None,
) -> tuple[list[str], int]:
    prepared = read_json(prepared_media_path)
    if prepared.get("errors"):
        raise WorkerError(f"Media preparation errors: {prepared.get('errors')}")
    selected = set(selected_shot_ids or [])
    items = [item for item in prepared.get("items", []) if item.get("role") == "current"]
    if selected:
        items = [item for item in items if str(item.get("shot_id") or "").lower() in selected]
    if not items:
        raise WorkerError("No selected current prepared stamped JPG files were produced for ZIP export.")
    zip_path.parent.mkdir(parents=True, exist_ok=True)
    used: set[str] = set()
    names: list[str] = []
    with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for item in sorted(items, key=lambda row: (str(row.get("prepared_media_filename") or "").lower(), str(row.get("shot_id") or ""))):
            source = pathlib.Path(item["temporary_prepared_path"])
            if not source.exists():
                raise WorkerError(f"Prepared stamped JPEG missing: {source}")
            name = str(item.get("prepared_media_filename") or source.name)
            lower = name.lower()
            if lower in used:
                stem = pathlib.PurePosixPath(name).stem
                suffix = pathlib.PurePosixPath(name).suffix or ".jpg"
                index = 2
                while f"{stem}_{index}{suffix}".lower() in used:
                    index += 1
                name = f"{stem}_{index}{suffix}"
                lower = name.lower()
            used.add(lower)
            archive.write(source, arcname=name)
            names.append(name)
    return names, zip_path.stat().st_size


def build_stamped_zip_export(
    args: argparse.Namespace,
    client: SupabaseServiceClient,
    repo: pathlib.Path,
    package: dict[str, Any],
    selected_shot_ids: list[str] | None = None,
    export: dict[str, Any] | None = None,
) -> dict[str, Any]:
    if not package_is_allowlisted(package, args):
        raise WorkerError("--stamped-zip-package-id package must be explicitly allowlisted by session or org/property.")

    snapshot_row = snapshot_metadata(client, package["snapshot_id"])
    selected_shot_ids = selected_shot_ids or []
    cache_key = stamped_zip_cache_key(package, snapshot_row, selected_shot_ids)
    if export is None:
        reusable = reusable_temporary_export(client, cache_key)
        if reusable:
            result = {
                "ok": True,
                "action": "reused",
                "package_id": package["id"],
                "export_id": reusable["id"],
                "status": reusable["status"],
                "cache_key": cache_key,
                "storage_bucket": reusable.get("storage_bucket"),
                "storage_path": reusable.get("storage_path"),
                "filename": reusable.get("filename"),
                "expires_at": reusable.get("expires_at"),
                "byte_size": reusable.get("byte_size"),
                "zip_entries": [],
            }
            print(stable_json(result, args.pretty))
            return result
        export = create_temporary_export(client, package, cache_key, args.requested_by_user_id)
        action = "created"
    else:
        action = "processed"
        if str(export.get("cache_key") or "") != cache_key:
            client.patch(
                "temporary_exports",
                {"id": f"eq.{export['id']}"},
                {
                    "status": "failed",
                    "locked_at": None,
                    "locked_by": None,
                    "last_error": "Queued stamped ZIP cache key did not match package snapshot metadata.",
                },
            )
            raise WorkerError(f"Queued stamped ZIP cache key mismatch for export {export['id']}.")
        if export.get("status") not in {"generating", "queued"}:
            raise WorkerError(f"Queued stamped ZIP export {export['id']} is not processable.")

    try:
        output_root = pathlib.Path(args.output_dir).resolve() / str(package["session_id"]).lower() / "stamped_zip"
        validation_path = output_root / "report_input_validation.json"
        media_dir = output_root / "prepared_media"
        zip_dir = output_root / "zip"
        output_root.mkdir(parents=True, exist_ok=True)
        env = dict(os.environ)

        run_step(
            [
                sys.executable,
                str(repo / "web-contract" / "report-input" / "report_input_phase1.py"),
                "--session-id",
                package["session_id"],
                "--snapshot-id",
                package["snapshot_id"],
                "--output",
                str(validation_path),
                "--pretty",
            ],
            repo,
            env,
        )
        validation = read_json(validation_path)
        if not validation.get("renderable_remotely"):
            raise WorkerError(f"ReportInput is not renderable remotely: {validation.get('gaps')}")
        if validation.get("media", {}).get("missing_count") != 0:
            raise WorkerError("ReportInput has missing remote media; refusing ZIP export.")

        run_step(
            [
                sys.executable,
                str(repo / "web-contract" / "report-media" / "report_media_phase2a.py"),
                "--validation-json",
                str(validation_path),
                "--output-dir",
                str(media_dir),
                "--pretty",
            ],
            repo,
            env,
        )
        prepared_media_path = media_dir / "prepared_report_media.json"
        filename = export_filename(validation, selected=bool(selected_shot_ids))
        zip_path = zip_dir / filename
        zip_entries, byte_size = zip_prepared_current_media(
            prepared_media_path,
            zip_path,
            selected_shot_ids,
        )
        zip_sha = sha256_file(zip_path)
        storage_path = expected_zip_path(package["org_id"], package["property_id"], package["session_id"], export["id"])
        client.upload_object(DELIVERABLES_BUCKET, storage_path, zip_path, "application/zip")
        expires_at = (dt.datetime.now(dt.timezone.utc) + dt.timedelta(hours=48)).isoformat().replace("+00:00", "Z")
        rows = client.patch(
            "temporary_exports",
            {"id": f"eq.{export['id']}"},
            {
                "status": "ready",
                "expires_at": expires_at,
                "storage_bucket": DELIVERABLES_BUCKET,
                "storage_path": storage_path,
                "filename": filename,
                "mime_type": "application/zip",
                "byte_size": byte_size,
                "sha256": zip_sha,
                "locked_at": None,
                "locked_by": None,
                "last_error": None,
            },
        )
        export = rows[0] if rows else export
    except Exception as error:
        client.patch(
            "temporary_exports",
            {"id": f"eq.{export['id']}"},
            {"status": "failed", "locked_at": None, "locked_by": None, "last_error": str(error)[:2000]},
        )
        raise

    result = {
        "ok": True,
        "action": action,
        "package_id": package["id"],
        "export_id": export["id"],
        "status": export.get("status"),
        "cache_key": cache_key,
        "storage_bucket": export.get("storage_bucket"),
        "storage_path": export.get("storage_path"),
        "filename": export.get("filename"),
        "expires_at": export.get("expires_at"),
        "byte_size": export.get("byte_size"),
        "sha256": export.get("sha256"),
        "selected_shot_ids": selected_shot_ids,
        "zip_entries": zip_entries,
        "local_zip_path": str(zip_path),
    }
    print(stable_json(result, args.pretty))
    return result


def generate_stamped_zip_export(
    args: argparse.Namespace,
    client: SupabaseServiceClient,
    repo: pathlib.Path,
) -> dict[str, Any]:
    package = select_ready_package(client, args.stamped_zip_package_id)
    selected_shot_ids = normalized_selected_shot_ids(args)
    return build_stamped_zip_export(args, client, repo, package, selected_shot_ids)


def discover_queued_stamped_exports(client: SupabaseServiceClient, limit: int) -> list[dict[str, Any]]:
    return client.select(
        "temporary_exports",
        {
            "select": "*",
            "artifact_type": "eq.stamped_jpg_zip",
            "status": "eq.queued",
            "deleted_at": "is.null",
            "order": "requested_at.asc",
            "limit": str(max(1, limit)),
        },
    )


def temporary_export_is_allowlisted(export_row: dict[str, Any], args: argparse.Namespace) -> bool:
    session_id = str(export_row.get("session_id") or "").lower()
    org_id = str(export_row.get("org_id") or "").lower()
    property_id = str(export_row.get("property_id") or "").lower()
    return session_id in allowed_session_ids(args) or (org_id, property_id) in allowed_org_properties(args)


def package_for_temporary_export(
    client: SupabaseServiceClient,
    export_row: dict[str, Any],
) -> dict[str, Any] | None:
    rows = client.select(
        "report_packages",
        {
            "select": "*",
            "org_id": f"eq.{export_row['org_id']}",
            "property_id": f"eq.{export_row['property_id']}",
            "session_id": f"eq.{export_row['session_id']}",
            "snapshot_id": f"eq.{export_row['snapshot_id']}",
            "status": "eq.ready",
            "deleted_at": "is.null",
            "order": "completed_at.desc",
            "limit": "1",
        },
    )
    return rows[0] if rows else None


def run_stamped_zip_poll_once(
    args: argparse.Namespace,
    client: SupabaseServiceClient,
    repo: pathlib.Path,
) -> dict[str, Any]:
    if not allowed_session_ids(args) and not allowed_org_properties(args):
        raise WorkerError("--stamped-zip-poll-once requires at least one --allow-session-id or --allow-org-property.")

    discovered = discover_queued_stamped_exports(client, args.stamped_zip_limit)
    summary: dict[str, Any] = {
        "ok": True,
        "mode": "stamped-zip-poll-once",
        "dry_run": bool(args.stamped_zip_poll_dry_run),
        "environment": client.environment,
        "local_dev_only": client.environment == "local-dev",
        "production_writes_made": False,
        "remote_validation_writes_made": client.environment == "remote-validation",
        "discovered_count": len(discovered),
        "processed": [],
        "skipped": [],
        "would_process": [],
    }

    for export_row in discovered:
        base_log = {
            "export_id": export_row.get("id"),
            "session_id": export_row.get("session_id"),
            "snapshot_id": export_row.get("snapshot_id"),
            "org_id": export_row.get("org_id"),
            "property_id": export_row.get("property_id"),
        }
        if not temporary_export_is_allowlisted(export_row, args):
            summary["skipped"].append({**base_log, "reason": "not_allowlisted"})
            continue
        if str(export_row.get("cache_key") or "").startswith("stamped-jpg-zip-selected:"):
            summary["skipped"].append({**base_log, "reason": "selected_export_queue_not_supported"})
            continue
        package = package_for_temporary_export(client, export_row)
        if not package:
            summary["skipped"].append({**base_log, "reason": "ready_package_not_found"})
            continue
        if args.stamped_zip_poll_dry_run:
            summary["would_process"].append({**base_log, "package_id": package["id"]})
            continue
        claimed = claim_temporary_export(client, export_row)
        if not claimed:
            summary["skipped"].append({**base_log, "reason": "already_claimed"})
            continue
        result = build_stamped_zip_export(args, client, repo, package, [], claimed)
        summary["processed"].append(
            {
                **base_log,
                "package_id": package["id"],
                "export_id": result["export_id"],
                "status": result["status"],
                "filename": result.get("filename"),
                "zip_entry_count": len(result.get("zip_entries") or []),
            }
        )

    output_path = pathlib.Path(args.output_dir).resolve() / "stamped_zip_poll_once_summary.json"
    write_json(output_path, summary, args.pretty)
    summary["summary_path"] = str(output_path)
    print(stable_json(summary, True))
    return summary


def retention_candidates(client: SupabaseServiceClient, property_id: str) -> list[dict[str, Any]]:
    rows = client.select(
        "report_packages",
        {
            "select": "id,property_id,session_id,status,session_completed_at,completed_at,storage_pruned_at",
            "property_id": f"eq.{property_id}",
            "status": "eq.ready",
            "deleted_at": "is.null",
            "order": "session_completed_at.desc,completed_at.desc",
        },
    )
    return rows[2:]


def apply_retention(client: SupabaseServiceClient, candidates: list[dict[str, Any]], mode: str) -> list[dict[str, Any]]:
    results: list[dict[str, Any]] = []
    for package in candidates:
        files = client.select(
            "report_package_files",
            {
                "select": "id,storage_bucket,storage_path,storage_deleted_at",
                "package_id": f"eq.{package['id']}",
                "deleted_at": "is.null",
            },
        )
        entry = {"package_id": package["id"], "mode": mode, "files": []}
        for file_row in files:
            file_entry = {
                "file_id": file_row["id"],
                "storage_bucket": file_row["storage_bucket"],
                "storage_path": file_row["storage_path"],
                "action": "would_delete" if mode == "dry-run" else "deleted",
            }
            if mode == "apply" and file_row.get("storage_deleted_at") is None:
                client.delete_object(file_row["storage_bucket"], file_row["storage_path"])
                client.patch(
                    "report_package_files",
                    {"id": f"eq.{file_row['id']}"},
                    {"storage_deleted_at": safe_iso_now()},
                )
            entry["files"].append(file_entry)
        if mode == "apply":
            client.patch("report_packages", {"id": f"eq.{package['id']}"}, {"status": "pruned", "storage_pruned_at": safe_iso_now()})
        results.append(entry)
    return results


def allowed_session_ids(args: argparse.Namespace) -> set[str]:
    return {item.lower() for item in args.allow_session_id}


def allowed_org_ids(args: argparse.Namespace) -> set[str]:
    return {item.strip().lower() for item in args.allow_org_id if item.strip()}


def allowed_org_properties(args: argparse.Namespace) -> set[tuple[str, str]]:
    allowed: set[tuple[str, str]] = set()
    for item in args.allow_org_property:
        if ":" not in item:
            raise WorkerError("--allow-org-property must be formatted as ORG_ID:PROPERTY_ID.")
        org_id, property_id = item.split(":", 1)
        org_id = org_id.strip().lower()
        property_id = property_id.strip().lower()
        if not org_id or not property_id:
            raise WorkerError("--allow-org-property must include both org and property IDs.")
        allowed.add((org_id, property_id))
    return allowed


def snapshot_is_allowlisted(
    snapshot: dict[str, Any],
    allowed_sessions: set[str],
    allowed_orgs: set[str],
    allowed_pairs: set[tuple[str, str]],
) -> bool:
    session_id = str(snapshot.get("session_id") or "").lower()
    org_id = str(snapshot.get("org_id") or "").lower()
    property_id = str(snapshot.get("property_id") or "").lower()
    return session_id in allowed_sessions or org_id in allowed_orgs or (org_id, property_id) in allowed_pairs


def ready_package_exists(client: SupabaseServiceClient, snapshot_id: str) -> bool:
    rows = client.select(
        "report_packages",
        {
            "select": "id",
            "snapshot_id": f"eq.{snapshot_id}",
            "status": "eq.ready",
            "deleted_at": "is.null",
            "limit": "1",
        },
    )
    return bool(rows)


def extension_for_storage_path(path: str) -> str:
    return pathlib.PurePosixPath(str(path or "")).suffix.lower().lstrip(".")


def shot_is_heic(row: dict[str, Any]) -> bool:
    return extension_for_storage_path(str(row.get("storage_path") or "")) in {"heic", "heif"}


def decode_preview_image(source_bytes: bytes, source_name: str) -> Any:
    try:
        from PIL import Image, ImageOps
        import pillow_heif

        pillow_heif.register_heif_opener()
    except Exception as error:
        raise WorkerError(f"HEIC preview generation requires Pillow and pillow-heif: {error}") from error

    try:
        image = Image.open(io.BytesIO(source_bytes))
        image.load()
    except Exception as error:
        raise WorkerError(f"Could not decode HEIC original for preview {source_name}: {error}") from error
    return ImageOps.exif_transpose(image).convert("RGB")


def save_preview_jpg(source_bytes: bytes, source_name: str, output_path: pathlib.Path, max_long_edge: int) -> dict[str, Any]:
    from PIL import Image

    image = decode_preview_image(source_bytes, source_name)
    source_width, source_height = image.size
    long_edge = max(source_width, source_height)
    if long_edge > max_long_edge > 0:
        scale = max_long_edge / long_edge
        image = image.resize(
            (max(1, round(source_width * scale)), max(1, round(source_height * scale))),
            Image.Resampling.LANCZOS,
        )
    output_path.parent.mkdir(parents=True, exist_ok=True)
    image.save(output_path, "JPEG", quality=84, optimize=True, progressive=True)
    data = output_path.read_bytes()
    return {
        "source_width": source_width,
        "source_height": source_height,
        "preview_width": image.size[0],
        "preview_height": image.size[1],
        "byte_size": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
        "magic_hex": data[:3].hex(),
    }


def select_session_for_preview(client: SupabaseServiceClient, session_id: str) -> dict[str, Any]:
    rows = client.select(
        "sessions",
        {
            "select": "id,org_id,property_id,status,deleted_at",
            "id": f"eq.{session_id}",
            "deleted_at": "is.null",
            "limit": "1",
        },
    )
    if not rows:
        raise WorkerError(f"Session not found for HEIC preview generation: {session_id}")
    return rows[0]


def select_shots_for_preview(client: SupabaseServiceClient, session: dict[str, Any]) -> list[dict[str, Any]]:
    return client.select(
        "shots",
        {
            "select": "id,org_id,property_id,session_id,storage_bucket,storage_path,byte_size,upload_state,deleted_at",
            "org_id": f"eq.{session['org_id']}",
            "session_id": f"eq.{session['id']}",
            "storage_bucket": "eq.scoutcapture-originals",
            "upload_state": "eq.uploaded",
            "deleted_at": "is.null",
            "order": "position.asc,captured_at.asc",
        },
    )


def run_heic_preview_generation(
    args: argparse.Namespace,
    client: SupabaseServiceClient,
) -> dict[str, Any]:
    requested_sessions = sorted({str(item).strip().lower() for item in args.heic_preview_session_id if str(item).strip()})
    if not requested_sessions:
        raise WorkerError("--heic-preview-session-id is required for HEIC preview generation.")

    output_root = pathlib.Path(args.output_dir).resolve() / "heic_previews"
    output_root.mkdir(parents=True, exist_ok=True)
    summary: dict[str, Any] = {
        "ok": True,
        "mode": "heic-preview-session",
        "environment": client.environment,
        "local_dev_only": client.environment == "local-dev",
        "production_writes_made": False,
        "remote_validation_writes_made": client.environment == "remote-validation",
        "preview_version": ORIGINAL_JPG_PREVIEW_VERSION,
        "storage_bucket": DELIVERABLES_BUCKET,
        "max_long_edge": args.heic_preview_max_long_edge,
        "sessions": [],
        "errors": [],
    }

    for session_id in requested_sessions:
        if session_id not in allowed_session_ids(args):
            raise WorkerError("--heic-preview-session-id must be explicitly included in --allow-session-id.")
        session = select_session_for_preview(client, session_id)
        session_allowlist_row = {
            "session_id": session["id"],
            "org_id": session["org_id"],
            "property_id": session["property_id"],
        }
        if not package_is_allowlisted(session_allowlist_row, args):
            raise WorkerError("HEIC preview session must be explicitly allowlisted by session or org/property.")

        rows = select_shots_for_preview(client, session)
        session_summary: dict[str, Any] = {
            "session_id": session_id,
            "org_id": session["org_id"],
            "property_id": session["property_id"],
            "total_originals": len(rows),
            "heic_originals": 0,
            "browser_previewable_originals": 0,
            "generated": 0,
            "existing": 0,
            "skipped_non_heic": 0,
            "failed": 0,
            "previews": [],
        }
        for row in rows:
            ext = extension_for_storage_path(str(row.get("storage_path") or ""))
            if ext in {"jpg", "jpeg", "png"}:
                session_summary["browser_previewable_originals"] += 1
                session_summary["skipped_non_heic"] += 1
                continue
            if not shot_is_heic(row):
                session_summary["skipped_non_heic"] += 1
                continue
            session_summary["heic_originals"] += 1
            preview_path = expected_original_jpg_preview_path(session["org_id"], session["property_id"], row["session_id"], row["id"])
            preview_entry = {
                "shot_id": row["id"],
                "source_storage_bucket": row["storage_bucket"],
                "source_storage_path": row["storage_path"],
                "preview_storage_bucket": DELIVERABLES_BUCKET,
                "preview_storage_path": preview_path,
            }
            try:
                if client.object_exists(DELIVERABLES_BUCKET, preview_path):
                    session_summary["existing"] += 1
                    preview_entry["action"] = "existing"
                else:
                    source_bytes = client.download_object(row["storage_bucket"], row["storage_path"])
                    local_path = output_root / session_id / f"{str(row['id']).lower()}.jpg"
                    preview_meta = save_preview_jpg(
                        source_bytes,
                        pathlib.PurePosixPath(row["storage_path"]).name,
                        local_path,
                        args.heic_preview_max_long_edge,
                    )
                    if preview_meta["magic_hex"] != "ffd8ff":
                        raise WorkerError(f"Preview JPEG magic mismatch for {row['id']}: {preview_meta['magic_hex']}")
                    client.upload_object(DELIVERABLES_BUCKET, preview_path, local_path, "image/jpeg")
                    session_summary["generated"] += 1
                    preview_entry.update({"action": "generated", **preview_meta, "local_path": str(local_path)})
            except Exception as error:
                session_summary["failed"] += 1
                preview_entry["action"] = "failed"
                preview_entry["error"] = str(error)
                summary["errors"].append({"session_id": session_id, "shot_id": row.get("id"), "error": str(error)})
            session_summary["previews"].append(preview_entry)
        summary["sessions"].append(session_summary)

    output_path = output_root / "heic_preview_summary.json"
    write_json(output_path, summary, args.pretty)
    summary["summary_path"] = str(output_path)
    print(stable_json(summary, True))
    return summary


def discover_poll_snapshots(client: SupabaseServiceClient) -> list[dict[str, Any]]:
    return client.select(
        "session_snapshots",
        {
            "select": "id,org_id,property_id,session_id,snapshot_kind,session_status,is_sealed,created_at",
            "snapshot_kind": "eq.completed",
            "is_sealed": "eq.true",
            "deleted_at": "is.null",
            "order": "created_at.asc",
        },
    )


def snapshot_sort_key(snapshot: dict[str, Any]) -> tuple[str, str]:
    return (
        str(snapshot.get("created_at") or ""),
        str(snapshot.get("id") or ""),
    )


def latest_snapshots_per_session(
    snapshots: list[dict[str, Any]]
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    latest_by_session: dict[str, dict[str, Any]] = {}
    superseded: list[dict[str, Any]] = []

    for snapshot in snapshots:
        session_id = str(snapshot.get("session_id") or "")
        if not session_id:
            superseded.append(snapshot)
            continue

        current = latest_by_session.get(session_id)
        if current is None:
            latest_by_session[session_id] = snapshot
            continue

        if snapshot_sort_key(snapshot) > snapshot_sort_key(current):
            superseded.append(current)
            latest_by_session[session_id] = snapshot
        else:
            superseded.append(snapshot)

    latest = sorted(latest_by_session.values(), key=snapshot_sort_key)
    superseded = sorted(superseded, key=snapshot_sort_key)
    return latest, superseded


def process_session(
    args: argparse.Namespace,
    client: SupabaseServiceClient,
    repo: pathlib.Path,
    session_id: str,
    snapshot_id: str | None = None,
) -> dict[str, Any]:
    output_root = pathlib.Path(args.output_dir).resolve() / session_id.lower()
    output_root.mkdir(parents=True, exist_ok=True)
    validation_path = output_root / "report_input_validation.json"
    media_dir = output_root / "prepared_media"
    render_dir = output_root / "rendered"
    summary_path = output_root / "worker_summary.json"

    env = dict(os.environ)
    logo_svg = repo / PACKAGED_LOGO_SVG
    if not logo_svg.exists():
        raise WorkerError(f"Packaged vector logo asset is missing: {logo_svg}")

    report_input_cmd = [
        sys.executable,
        str(repo / "web-contract" / "report-input" / "report_input_phase1.py"),
        "--session-id",
        session_id,
        "--output",
        str(validation_path),
        "--pretty",
    ]
    if snapshot_id:
        report_input_cmd.extend(["--snapshot-id", snapshot_id])
    run_step(report_input_cmd, repo, env)
    validation = read_json(validation_path)
    if not validation.get("renderable_remotely"):
        raise WorkerError(f"ReportInput is not renderable remotely: {validation.get('gaps')}")
    if validation.get("media", {}).get("missing_count") != 0:
        raise WorkerError("ReportInput has missing remote media; refusing to continue.")

    attempt_started_at = safe_iso_now()
    package = None
    package_action = None
    try:
        package, package_action = get_or_create_package(client, validation, attempt_started_at)
        snapshot_row = snapshot_metadata(client, validation["source_snapshot_id"])

        run_step(
            [
                sys.executable,
                str(repo / "web-contract" / "report-media" / "report_media_phase2a.py"),
                "--validation-json",
                str(validation_path),
                "--output-dir",
                str(media_dir),
                "--include-previous",
                "--pretty",
            ],
            repo,
            env,
        )
        prepared_media_path = media_dir / "prepared_report_media.json"
        prepared = read_json(prepared_media_path)
        if prepared.get("errors"):
            raise WorkerError(f"Media preparation errors: {prepared.get('errors')}")

        render_cmd = [
            sys.executable,
            str(repo / "web-contract" / "report-renderer" / "report_renderer_phase2b.py"),
            "--validation-json",
            str(validation_path),
            "--prepared-media-json",
            str(prepared_media_path),
            "--output-dir",
            str(render_dir),
            "--report",
            "all",
            "--report-date",
            report_date(validation),
            "--logo-pdf",
            str(repo / DISABLED_LOGO_PDF),
            "--logo-svg",
            str(logo_svg),
            "--pretty",
        ]
        if args.allow_weather_fetch:
            render_cmd.append("--allow-weather-fetch")
        run_step(render_cmd, repo, env)

        render_summary = read_json(render_dir / "phase2c_summary.json")
        failed = [item for item in render_summary.get("reports", []) if item.get("validation_failures")]
        if failed:
            raise WorkerError(f"PDF validation failures: {failed}")
        if not render_summary.get("reports"):
            raise WorkerError(f"No applicable PDF reports were generated: {render_summary.get('skipped_reports')}")
    except Exception as error:
        if package is not None:
            client.patch(
                "report_packages",
                {"id": f"eq.{package['id']}"},
                {
                    "status": "failed",
                    "locked_at": None,
                    "locked_by": None,
                    "last_error": str(error)[:2000],
                },
            )
        raise

    try:
        uploaded_files = []
        report_plan_hashes = []
        for report in render_summary.get("reports", []):
            report_type = REPORT_TYPE_MAP[report["report_type"]]
            pdf_path = pathlib.Path(report["pdf_path"])
            output_filename = report.get("output_filename") or pdf_path.name
            pdf_sha = report["pdf_sha256"]
            if sha256_file(pdf_path) != pdf_sha:
                raise WorkerError(f"PDF hash mismatch before upload: {pdf_path}")
            storage_path = path_for_pdf(package["org_id"], package["property_id"], package["session_id"], package["id"], report_type)
            client.upload_object(DELIVERABLES_BUCKET, storage_path, pdf_path, "application/pdf")
            file_row = upsert_file_row(
                client,
                package,
                report_type,
                output_filename,
                pdf_path,
                pdf_sha,
                int(report["page_count"]),
            )
            uploaded_files.append(
                {
                    "report_type": report_type,
                    "file_row_id": file_row["id"],
                    "filename": output_filename,
                    "storage_bucket": DELIVERABLES_BUCKET,
                    "storage_path": storage_path,
                    "pdf_sha256": pdf_sha,
                    "page_count": report["page_count"],
                    "byte_size": pdf_path.stat().st_size,
                    "local_pdf_path": str(pdf_path),
                }
            )
            report_plan_hashes.append(report["report_plan_sha256"])

        completed_at = safe_iso_now()
        package_rows = client.patch(
            "report_packages",
            {"id": f"eq.{package['id']}"},
            {
                "status": "ready",
                "completed_at": completed_at,
                "locked_at": None,
                "locked_by": None,
                "last_error": None,
                "renderer_version": render_summary.get("generator_version") or RENDERER_VERSION,
                "report_contract_version": REPORT_CONTRACT_VERSION,
                "media_preparer_version": MEDIA_PREPARER_VERSION,
                "raw_session_json_sha256": snapshot_row.get("raw_session_json_sha256"),
                "snapshot_payload_sha256": snapshot_row.get("snapshot_payload_sha256"),
                "report_input_sha256": sha256_file(validation_path),
                "prepared_media_manifest_sha256": sha256_file(prepared_media_path),
                "report_plan_sha256": sha256_text("\n".join(sorted(report_plan_hashes))),
                "weather_summary": (render_summary.get("weather") or {}).get("summary"),
                "weather_source": (render_summary.get("weather") or {}).get("source"),
                "weather_metadata": render_summary.get("weather") or {},
                "validation_summary": {
                    "report_count": len(uploaded_files),
                    "skipped_reports": render_summary.get("skipped_reports", []),
                    "pdf_validation_failures": [],
                },
                "manifest": {
                    "worker": "web-contract/report-production/report_worker_cli.py",
                    "environment": client.environment,
                    "production_writes_made": False,
                    "remote_validation_writes_made": client.environment == "remote-validation",
                    "local_dev_writes_made": client.environment == "local-dev",
                    "reports": uploaded_files,
                    "skipped_reports": render_summary.get("skipped_reports", []),
                },
            },
        )
        if package_rows:
            package = package_rows[0]

        candidates = retention_candidates(client, package["property_id"])
        retention = apply_retention(client, candidates, args.retention_mode)
    except Exception as error:
        client.patch(
            "report_packages",
            {"id": f"eq.{package['id']}"},
            {
                "status": "failed",
                "locked_at": None,
                "locked_by": None,
                "last_error": str(error)[:2000],
            },
        )
        raise
    summary = {
        "ok": True,
        "environment": client.environment,
        "local_dev_only": client.environment == "local-dev",
        "production_writes_made": False,
        "remote_validation_writes_made": client.environment == "remote-validation",
        "session_id": session_id,
        "snapshot_id": validation["source_snapshot_id"],
        "package_id": package["id"],
        "package_action": package_action,
        "package_status": package["status"],
        "output_root": str(output_root),
        "validation_json": str(validation_path),
        "prepared_media_json": str(prepared_media_path),
        "render_summary_json": str(render_dir / "phase2c_summary.json"),
        "uploaded_files": uploaded_files,
        "skipped_reports": render_summary.get("skipped_reports", []),
        "retention": {
            "mode": args.retention_mode,
            "candidate_count": len(candidates),
            "actions": retention,
        },
    }
    write_json(summary_path, summary, args.pretty)
    print(stable_json({"ok": True, "session_id": session_id, "package_id": package["id"], "package_action": package_action, "uploaded_files": uploaded_files, "skipped_reports": summary["skipped_reports"], "retention": summary["retention"], "summary_path": str(summary_path)}, True))
    return summary


def run_poll_once(
    args: argparse.Namespace,
    client: SupabaseServiceClient,
    repo: pathlib.Path,
) -> dict[str, Any]:
    allowed_sessions = allowed_session_ids(args)
    allowed_orgs = allowed_org_ids(args)
    allowed_pairs = allowed_org_properties(args)
    if not allowed_sessions and not allowed_orgs and not allowed_pairs:
        raise WorkerError("--poll-once requires at least one --allow-session-id, --allow-org-id, or --allow-org-property.")

    discovered = discover_poll_snapshots(client)
    latest_snapshots, superseded_snapshots = latest_snapshots_per_session(discovered)
    poll_summary: dict[str, Any] = {
        "ok": True,
        "mode": "poll-once",
        "dry_run": bool(args.poll_dry_run),
        "environment": client.environment,
        "local_dev_only": client.environment == "local-dev",
        "production_writes_made": False,
        "remote_validation_writes_made": client.environment == "remote-validation",
        "allow_session_ids": sorted(allowed_sessions),
        "allow_org_ids": sorted(allowed_orgs),
        "allow_org_properties": [f"{org_id}:{property_id}" for org_id, property_id in sorted(allowed_pairs)],
        "discovered_count": len(discovered),
        "latest_snapshot_count": len(latest_snapshots),
        "superseded_snapshot_count": len(superseded_snapshots),
        "processed": [],
        "skipped": [],
        "would_process": [],
    }

    for snapshot in superseded_snapshots:
        session_id = str(snapshot.get("session_id") or "")
        poll_summary["skipped"].append(
            {
                "snapshot_id": str(snapshot.get("id") or ""),
                "session_id": session_id,
                "org_id": snapshot.get("org_id"),
                "property_id": snapshot.get("property_id"),
                "reason": "superseded_by_newer_session_snapshot",
            }
        )

    for snapshot in latest_snapshots:
        session_id = str(snapshot.get("session_id") or "")
        snapshot_id = str(snapshot.get("id") or "")
        base_log = {
            "snapshot_id": snapshot_id,
            "session_id": session_id,
            "org_id": snapshot.get("org_id"),
            "property_id": snapshot.get("property_id"),
        }
        if not snapshot_is_allowlisted(snapshot, allowed_sessions, allowed_orgs, allowed_pairs):
            poll_summary["skipped"].append({**base_log, "reason": "not_allowlisted"})
            continue
        if ready_package_exists(client, snapshot_id):
            poll_summary["skipped"].append({**base_log, "reason": "ready_package_exists"})
            continue

        if args.poll_dry_run:
            poll_summary["would_process"].append({**base_log, "reason": "allowlisted_missing_ready_package"})
            continue

        print(stable_json({"poll": "processing", **base_log}, True))
        result = process_session(args, client, repo, session_id, snapshot_id)
        poll_summary["processed"].append(
            {
                **base_log,
                "package_id": result["package_id"],
                "package_action": result["package_action"],
                "file_count": len(result["uploaded_files"]),
                "skipped_reports": result.get("skipped_reports", []),
                "retention": result["retention"],
            }
        )

    output_path = pathlib.Path(args.output_dir).resolve() / "poll_once_summary.json"
    write_json(output_path, poll_summary, args.pretty)
    poll_summary["summary_path"] = str(output_path)
    print(stable_json(poll_summary, True))
    return poll_summary


def main() -> int:
    args = parse_args()
    if args.runtime_check:
        ok, details = runtime_check(args.require_heif)
        print(stable_json(details, args.pretty))
        return 0 if ok else 1

    repo = pathlib.Path(__file__).resolve().parents[2]
    client = SupabaseServiceClient.from_env(args)

    if args.stamped_zip_poll_once:
        run_stamped_zip_poll_once(args, client, repo)
        return 0

    if args.heic_preview_session_id:
        summary = run_heic_preview_generation(args, client)
        return 0 if not summary.get("errors") else 1

    if args.stamped_zip_package_id:
        generate_stamped_zip_export(args, client, repo)
        return 0

    if args.poll_once:
        run_poll_once(args, client, repo)
        return 0

    if not args.session_id:
        raise WorkerError("--session-id is required unless --poll-once is used.")
    if args.snapshot_id and not args.session_id:
        raise WorkerError("--snapshot-id requires --session-id.")
    if args.session_id.lower() not in allowed_session_ids(args):
        raise WorkerError("--session-id must be explicitly included in --allow-session-id.")
    process_session(args, client, repo, args.session_id, args.snapshot_id)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except WorkerError as error:
        print(stable_json({"ok": False, "error": str(error)}, True), file=sys.stderr)
        raise SystemExit(1)
