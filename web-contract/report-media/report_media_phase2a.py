#!/usr/bin/env python3
"""ScoutCapture Phase 2A read-only report media preparer.

Consumes Phase 1 ReportInput validation JSON and writes temporary prepared JPEGs
plus a deterministic PreparedReportMedia manifest. No PDFs are generated and no
remote writes are performed.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import pathlib
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Any
from zoneinfo import ZoneInfo

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "shared"))

try:
    from PIL import Image, ImageDraw, ImageFont, ImageOps
except Exception as error:  # pragma: no cover - dependency check path
    raise SystemExit(f"Pillow is required for Phase 2A media preparation: {error}")

HEIF_DECODER = None
try:  # Production Linux/container path when pillow-heif is installed.
    import pillow_heif

    pillow_heif.register_heif_opener()
    HEIF_DECODER = "pillow-heif"
except Exception:
    HEIF_DECODER = None

from scout_report_visuals import (
    filled_flag_polygon,
    visual_state_rgb,
)


JPEG_QUALITY = 85
STAMPED_MAX_LONG_EDGE = 2400
OUTPUT_MIME_TYPE = "image/jpeg"
ORIGINALS_BUCKET = "scoutcapture-originals"
DISPLAY_TZ = ZoneInfo("America/New_York")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--validation-json", required=True, help="Phase 1 validation JSON.")
    parser.add_argument("--output-dir", required=True, help="Local non-production output directory.")
    parser.add_argument("--include-previous", action="store_true", help="Also prepare previous comparison media.")
    parser.add_argument("--limit", type=int, help="Maximum media items to prepare.")
    parser.add_argument("--pretty", action="store_true", help="Pretty-print manifest JSON.")
    return parser.parse_args()


class Phase2AError(RuntimeError):
    pass


class SupabaseReadClient:
    def __init__(self, url: str, key: str) -> None:
        self.url = url.rstrip("/")
        self.key = key

    @classmethod
    def from_env(cls) -> "SupabaseReadClient":
        url = os.environ.get("SUPABASE_URL", "").strip()
        key = (
            os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "").strip()
            or os.environ.get("SUPABASE_ANON_KEY", "").strip()
            or os.environ.get("SUPABASE_ACCESS_TOKEN", "").strip()
        )
        if not url or not key:
            raise Phase2AError("SUPABASE_URL and a read-capable key are required.")
        return cls(url, key)

    def _request(self, method: str, url: str, accept: str = "application/json") -> bytes:
        req = urllib.request.Request(url, method=method)
        req.add_header("apikey", self.key)
        req.add_header("Authorization", f"Bearer {self.key}")
        req.add_header("Accept", accept)
        try:
            with urllib.request.urlopen(req, timeout=60) as response:
                return response.read()
        except urllib.error.HTTPError as error:
            detail = error.read().decode("utf-8", errors="replace")
            raise Phase2AError(f"Supabase read failed {method}: {error.code} {detail}") from error

    def download_object(self, bucket: str, path: str) -> bytes:
        encoded_path = "/".join(urllib.parse.quote(part) for part in path.split("/"))
        url = f"{self.url}/storage/v1/object/{urllib.parse.quote(bucket)}/{encoded_path}"
        return self._request("GET", url, accept="*/*")

    def select_rows(self, table: str, query: dict[str, str]) -> list[dict[str, Any]]:
        encoded = urllib.parse.urlencode(query, safe="(),.*")
        url = f"{self.url}/rest/v1/{table}?{encoded}"
        value = json.loads(self._request("GET", url).decode("utf-8"))
        if not isinstance(value, list):
            raise Phase2AError(f"Expected list response from {table}.")
        return value


@dataclass(frozen=True)
class MediaItem:
    role: str
    shot_id: str
    session_id: str | None
    source_bucket: str
    source_path: str
    source_filename: str
    building: str | None
    elevation: str | None
    detail_type: str | None
    angle_index: int | None
    shot_key: str | None
    captured_at_utc: str | None
    is_flagged: bool
    is_resolved_in_session: bool
    session_completed_at_utc: str | None = None
    session_exported_at_utc: str | None = None
    session_ended_at_utc: str | None = None


def stable_json(data: Any, pretty: bool) -> str:
    if pretty:
        return json.dumps(data, sort_keys=True, indent=2, separators=(",", ": ")) + "\n"
    return json.dumps(data, sort_keys=True, separators=(",", ":")) + "\n"


def trim(value: Any) -> str | None:
    if value is None:
        return None
    text = str(value).strip()
    return text or None


def safe_int(value: Any) -> int | None:
    if value is None:
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def sanitize_component(value: Any) -> str:
    raw = trim(value) or ""
    chars = []
    forbidden = set('/\\:*?"<>|')
    for ch in raw:
        if ord(ch) < 32 or ch in forbidden:
            chars.append("_")
        elif ch == " ":
            chars.append("_")
        else:
            chars.append(ch)
    collapsed = re.sub(r"_+", "_", "".join(chars)).strip("_")
    return collapsed or "Item"


def normalized_detail_id(shot_key: Any, angle_index: Any) -> str:
    key = trim(shot_key)
    if key and re.match(r"^A\d+$", key.upper()):
        return key.upper()
    return f"A{safe_int(angle_index) if safe_int(angle_index) is not None else 0}"


def stamped_filename(item: MediaItem) -> str:
    detail_id = normalized_detail_id(item.shot_key, item.angle_index)
    shot_name = trim(item.detail_type) or "Shot"
    base = "_".join(
        [
            sanitize_component(item.building),
            sanitize_component(item.elevation),
            sanitize_component(shot_name),
            sanitize_component(detail_id),
        ]
    )
    suffix = "_Flagged" if item.is_flagged or item.is_resolved_in_session else ""
    return f"{base}{suffix}.jpg"


def make_stamp_text(item: MediaItem) -> tuple[str, list[str]]:
    warnings = []
    date_text = format_local_date(item.captured_at_utc)
    if not item.captured_at_utc:
        warnings.append("captured_at_missing_would_be_wall_clock_in_scoutprocess")
    text = " | ".join(
        [
            trim(item.building) or "B1",
            trim(item.elevation) or "North",
            trim(item.detail_type) or "General Elevation",
            f"{normalized_detail_id(item.shot_key, item.angle_index)} • {date_text}",
        ]
    )
    return text.upper(), warnings


def format_local_date(raw: str | None) -> str:
    if not raw:
        now = dt.datetime.now(DISPLAY_TZ)
        return f"{now.strftime('%b')} {now.day}, {now.year}"
    normalized = raw.replace("Z", "+00:00")
    try:
        parsed = dt.datetime.fromisoformat(normalized)
    except ValueError:
        return raw
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.timezone.utc)
    local = parsed.astimezone(DISPLAY_TZ)
    return f"{local.strftime('%b')} {local.day}, {local.year}"


def load_font(size: int) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    candidates = [
        "/System/Library/Fonts/SFNS.ttf",
        "/System/Library/Fonts/Supplemental/Arial.ttf",
        "/Library/Fonts/Arial.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/dejavu/DejaVuSans.ttf",
    ]
    for path in candidates:
        if pathlib.Path(path).exists():
            try:
                return ImageFont.truetype(path, size=size)
            except Exception:
                pass
    return ImageFont.load_default()


def text_width(draw: ImageDraw.ImageDraw, text: str, font: ImageFont.ImageFont) -> float:
    bbox = draw.textbbox((0, 0), text, font=font)
    return float(bbox[2] - bbox[0])


def text_size(draw: ImageDraw.ImageDraw, text: str, font: ImageFont.ImageFont) -> tuple[float, float]:
    bbox = draw.textbbox((0, 0), text, font=font)
    return float(bbox[2] - bbox[0]), float(bbox[3] - bbox[1])


def fitted_stamp_text(draw: ImageDraw.ImageDraw, stamp_text: str, max_text_width: float, font: ImageFont.ImageFont) -> str:
    if text_width(draw, stamp_text, font) <= max_text_width:
        return stamp_text
    major = stamp_text.split(" | ")
    if len(major) != 4:
        return stamp_text
    tail = major[3].split(" • ")
    if len(tail) != 2:
        return stamp_text
    prefix = f"{major[0]} | {major[1]} | "
    detail_and_date = f" | {tail[0]} • {tail[1]}"
    shot_name = major[2]
    while len(shot_name) > 4:
        shot_name = shot_name[:-1]
        candidate = f"{prefix}{shot_name}...{detail_and_date}"
        if text_width(draw, candidate, font) <= max_text_width:
            return candidate
    return f"{prefix}...{detail_and_date}"


def decode_image(source_path: pathlib.Path, work_dir: pathlib.Path) -> tuple[Image.Image, str, list[str]]:
    warnings = []
    try:
        image = Image.open(source_path)
        image.load()
        orientation = str(image.getexif().get(274, "unknown"))
        if source_path.suffix.lower() in {".heic", ".heif"} and HEIF_DECODER:
            warnings.append(f"heic_decoded_with_{HEIF_DECODER}")
        return ImageOps.exif_transpose(image), orientation, warnings
    except Exception as pillow_error:
        ext = source_path.suffix.lower()
        if ext in {".heic", ".heif"} and platform.system() == "Darwin" and shutil.which("sips"):
            converted = work_dir / f"{source_path.stem}.sips.png"
            subprocess.run(
                ["sips", "-s", "format", "png", str(source_path), "--out", str(converted)],
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=60,
            )
            image = Image.open(converted)
            image.load()
            warnings.append("heic_decoded_with_macos_sips_shadow_fallback")
            return image.convert("RGBA"), "sips_applied_or_unknown", warnings
        raise Phase2AError(f"Could not decode image {source_path.name}: {pillow_error}") from pillow_error


def scale_size(width: int, height: int) -> tuple[int, int]:
    long_edge = max(width, height)
    if long_edge <= 0 or long_edge <= STAMPED_MAX_LONG_EDGE:
        return max(1, round(width)), max(1, round(height))
    scale = STAMPED_MAX_LONG_EDGE / long_edge
    return max(1, round(width * scale)), max(1, round(height * scale))


def draw_flag(draw: ImageDraw.ImageDraw, x: float, y: float, size: float, state: str) -> None:
    color = (*visual_state_rgb(state), 255)
    points = filled_flag_polygon()

    def transform(point: tuple[float, float]) -> tuple[float, float]:
        return x + (point[0] / 24.0) * size, y + (point[1] / 24.0) * size

    draw.polygon([transform(point) for point in points], fill=color)


def prepare_image(item: MediaItem, source_path: pathlib.Path, output_path: pathlib.Path, work_dir: pathlib.Path) -> dict[str, Any]:
    image, orientation, decode_warnings = decode_image(source_path, work_dir)
    image = image.convert("RGBA")
    original_width, original_height = image.size
    out_width, out_height = scale_size(original_width, original_height)
    if (out_width, out_height) != image.size:
        image = image.resize((out_width, out_height), Image.Resampling.LANCZOS)

    overlay = Image.new("RGBA", image.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    is_portrait = out_height > out_width
    output_long_edge = max(out_width, out_height)
    overlay_scale = max(min(output_long_edge / STAMPED_MAX_LONG_EDGE, 1), 0.72)
    font_size = max((43 if is_portrait else 37) * overlay_scale, 27 if is_portrait else 23)
    pill_height = max((84 if is_portrait else 74) * overlay_scale, 58 if is_portrait else 52)
    horizontal_padding = max((26 if is_portrait else 23) * overlay_scale, 17)
    vertical_padding = max((16 if is_portrait else 15) * overlay_scale, 11)
    bottom_margin = max((36 if is_portrait else 32) * overlay_scale, 22)
    side_margin = max((36 if is_portrait else 32) * overlay_scale, 22)
    corner_radius = max((19 if is_portrait else 17) * overlay_scale, 13)
    max_overlay_width = out_width - (side_margin * 2)

    visual_state = "resolved" if item.is_resolved_in_session else "flagged" if item.is_flagged else "none"
    shows_flag = visual_state != "none"
    glyph_size = font_size * 0.82 if shows_flag else 0
    glyph_gap = max(11 * overlay_scale, 8) if shows_flag else 0
    font = load_font(round(font_size))
    stamp_text, stamp_warnings = make_stamp_text(item)
    resolved_text = fitted_stamp_text(draw, stamp_text, max_overlay_width - (horizontal_padding * 2) - glyph_size - glyph_gap, font)
    measured_width, measured_height = text_size(draw, resolved_text, font)
    pill_width = min(max_overlay_width, measured_width + (horizontal_padding * 2) + glyph_size + glyph_gap)
    pill_x = out_width - side_margin - pill_width
    pill_y = out_height - bottom_margin - pill_height
    pill_rect = (pill_x, pill_y, pill_x + pill_width, pill_y + pill_height)
    draw.rounded_rectangle(pill_rect, radius=corner_radius, fill=(0, 0, 0, round(255 * 0.42)))

    text_x = pill_x + horizontal_padding
    if shows_flag:
        glyph_y = pill_y + max(0, (pill_height - glyph_size) / 2) - 1
        draw_flag(draw, text_x, glyph_y, glyph_size, visual_state)
        text_x += glyph_size + glyph_gap
    text_y = pill_y + max(0, (pill_height - measured_height) / 2) - 1
    draw.text((text_x, text_y), resolved_text, fill=(255, 255, 255, 255), font=font)

    rendered = Image.alpha_composite(image, overlay).convert("RGB")
    output_path.parent.mkdir(parents=True, exist_ok=True)
    rendered.save(output_path, "JPEG", quality=JPEG_QUALITY)
    content = output_path.read_bytes()
    return {
        "prepared_media_filename": output_path.name,
        "prepared_media_mime_type": OUTPUT_MIME_TYPE,
        "prepared_width": out_width,
        "prepared_height": out_height,
        "image_orientation": orientation,
        "source_width": original_width,
        "source_height": original_height,
        "transformation_operations": [
            "decode_original",
            "apply_exif_transpose_or_decoder_orientation",
            f"scale_long_edge_to_max_{STAMPED_MAX_LONG_EDGE}",
            "draw_bottom_right_translucent_stamp_pill",
            f"draw_visual_state_{visual_state}",
            f"jpeg_quality_{JPEG_QUALITY}",
        ],
        "flag_resolved_state_applied": visual_state,
        "stamp_text": resolved_text,
        "deterministic_content_hash": hashlib.sha256(content).hexdigest(),
        "byte_size": len(content),
        "warnings": decode_warnings + stamp_warnings,
    }


def current_media_items(validation: dict[str, Any]) -> list[MediaItem]:
    result = []
    session = validation.get("inputs", {}).get("session", {})
    for shot in validation["inputs"]["ordered_shots"]:
        media = shot["media"]
        result.append(
            MediaItem(
                role="current",
                shot_id=str(shot["shot_id"]),
                session_id=str(shot.get("session_id") or validation.get("session_id") or ""),
                source_bucket=media.get("bucket") or ORIGINALS_BUCKET,
                source_path=media["path"],
                source_filename=pathlib.PurePosixPath(media["path"]).name,
                building=shot.get("building"),
                elevation=shot.get("elevation"),
                detail_type=shot.get("detail_type"),
                angle_index=safe_int(shot.get("angle_index")),
                shot_key=shot.get("shot_key"),
                captured_at_utc=shot.get("captured_at_utc"),
                session_completed_at_utc=session.get("ended_at_utc"),
                session_exported_at_utc=session.get("exported_at_utc"),
                session_ended_at_utc=session.get("ended_at_utc"),
                is_flagged=bool(shot.get("is_flagged")),
                is_resolved_in_session=bool(shot.get("is_resolved_in_session")),
            )
        )
    return result


def previous_media_items(validation: dict[str, Any], client: SupabaseReadClient) -> list[MediaItem]:
    result = []
    comparison_by_previous_id = {
        str(item.get("previous_shot_id")).lower(): item
        for item in validation.get("comparisons", {}).get("items", [])
        if item.get("previous_shot_id")
    }
    previous_ids = sorted(
        {
            item.get("previous_shot_id")
            for item in validation.get("comparisons", {}).get("items", [])
            if item.get("previous_shot_id")
        }
    )
    for shot_id in previous_ids:
        rows = client.select_rows(
            "shots",
            {
                "select": "id,session_id,building,elevation,detail_type,angle_index,shot_key,captured_at,storage_bucket,storage_path,is_flagged,issue_status",
                "id": f"eq.{shot_id}",
                "limit": "1",
            },
        )
        if not rows:
            continue
        row = rows[0]
        comparison = comparison_by_previous_id.get(str(shot_id).lower()) or {}
        path = row.get("storage_path")
        if not path:
            continue
        result.append(
            MediaItem(
                role="previous",
                shot_id=str(row["id"]),
                session_id=str(row.get("session_id") or ""),
                source_bucket=row.get("storage_bucket") or ORIGINALS_BUCKET,
                source_path=path,
                source_filename=pathlib.PurePosixPath(path).name,
                building=row.get("building"),
                elevation=row.get("elevation"),
                detail_type=row.get("detail_type"),
                angle_index=safe_int(row.get("angle_index")),
                shot_key=row.get("shot_key"),
                captured_at_utc=comparison.get("previous_captured_at_utc") or row.get("captured_at"),
                session_completed_at_utc=comparison.get("previous_session_completed_at_utc"),
                session_exported_at_utc=comparison.get("previous_session_exported_at_utc"),
                session_ended_at_utc=comparison.get("previous_session_ended_at_utc"),
                is_flagged=bool(row.get("is_flagged")),
                is_resolved_in_session=(trim(row.get("issue_status")) or "").lower() == "resolved",
            )
        )
    return result


def unique_output_name(preferred: str, used: set[str]) -> str:
    lower = preferred.lower()
    if lower not in used:
        used.add(lower)
        return preferred
    base = pathlib.PurePosixPath(preferred).stem
    ext = pathlib.PurePosixPath(preferred).suffix or ".jpg"
    for index in range(2, 1000):
        candidate = f"{base}_{index}{ext}"
        if candidate.lower() not in used:
            used.add(candidate.lower())
            return candidate
    used.add(lower)
    return preferred


def main() -> int:
    args = parse_args()
    validation_path = pathlib.Path(args.validation_json)
    output_dir = pathlib.Path(args.output_dir)
    downloads_dir = output_dir / "downloads"
    prepared_dir = output_dir / "prepared"
    temp_dir = output_dir / "tmp"
    downloads_dir.mkdir(parents=True, exist_ok=True)
    prepared_dir.mkdir(parents=True, exist_ok=True)
    temp_dir.mkdir(parents=True, exist_ok=True)

    validation = json.loads(validation_path.read_text(encoding="utf-8"))
    client = SupabaseReadClient.from_env()
    items = current_media_items(validation)
    if args.include_previous:
        items.extend(previous_media_items(validation, client))
    if args.limit is not None:
        items = items[: args.limit]

    prepared = []
    errors = []
    used_names_by_folder: dict[str, set[str]] = {}
    for item in items:
        try:
            source_bytes = client.download_object(item.source_bucket, item.source_path)
            source_hash = hashlib.sha256(source_bytes).hexdigest()
            source_ext = pathlib.PurePosixPath(item.source_filename).suffix or ".bin"
            local_source = downloads_dir / f"{item.role}_{item.shot_id.lower()}{source_ext.lower()}"
            local_source.write_bytes(source_bytes)
            folder_key = f"{item.role}/{(item.session_id or 'unknown-session').lower()}"
            used_names = used_names_by_folder.setdefault(folder_key, set())
            prepared_name = unique_output_name(stamped_filename(item), used_names)
            prepared_path = prepared_dir / folder_key / prepared_name
            result = prepare_image(item, local_source, prepared_path, temp_dir)
            prepared.append(
                {
                    "role": item.role,
                    "shot_id": item.shot_id,
                    "session_id": item.session_id,
                    "source_storage_bucket": item.source_bucket,
                    "source_storage_path": item.source_path,
                    "source_filename": item.source_filename,
                    "captured_at_utc": item.captured_at_utc,
                    "session_completed_at_utc": item.session_completed_at_utc,
                    "session_exported_at_utc": item.session_exported_at_utc,
                    "session_ended_at_utc": item.session_ended_at_utc,
                    "source_sha256": source_hash,
                    "temporary_source_path": str(local_source),
                    "temporary_prepared_path": str(prepared_path),
                    **result,
                }
            )
        except Exception as error:
            errors.append(
                {
                    "role": item.role,
                    "shot_id": item.shot_id,
                    "source_storage_bucket": item.source_bucket,
                    "source_storage_path": item.source_path,
                    "error": type(error).__name__,
                    "message": str(error),
                }
            )

    manifest = {
        "schema_version": 1,
        "phase": "ScoutCapture Phase 2A PreparedReportMedia",
        "source_validation_json": str(validation_path),
        "session_id": validation.get("session_id"),
        "property_id": validation.get("inputs", {}).get("session", {}).get("property_id"),
        "source_snapshot_id": validation.get("source_snapshot_id"),
        "read_only_remote_access": True,
        "production_writes_made": False,
        "renderer": {
            "tool": "web-contract/report-media/report_media_phase2a.py",
            "technology": "Python Pillow with macOS sips HEIC shadow fallback",
            "jpeg_quality": JPEG_QUALITY,
            "max_long_edge": STAMPED_MAX_LONG_EDGE,
        },
        "counts": {
            "requested": len(items),
            "prepared": len(prepared),
            "failed": len(errors),
            "current": len([item for item in prepared if item["role"] == "current"]),
            "previous": len([item for item in prepared if item["role"] == "previous"]),
        },
        "items": sorted(prepared, key=lambda item: (item["role"], item["shot_id"])),
        "errors": errors,
        "warnings": sorted({warning for item in prepared for warning in item.get("warnings", [])}),
    }
    (output_dir / "prepared_report_media.json").write_text(stable_json(manifest, args.pretty), encoding="utf-8")
    sys.stdout.write(stable_json({"ok": not errors, "manifest": str(output_dir / "prepared_report_media.json"), "counts": manifest["counts"], "warnings": manifest["warnings"]}, True))
    return 0 if not errors else 2


if __name__ == "__main__":
    raise SystemExit(main())
