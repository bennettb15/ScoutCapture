#!/usr/bin/env python3
"""ScoutCapture Phase 2C shadow PDF renderer.

Consumes Phase 1/1B ReportInput validation JSON plus Phase 2A
PreparedReportMedia JSON and writes local shadow PDFs, deterministic ReportPlans,
validation manifests, and preview contact sheets.

No remote writes are performed.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import math
import os
import pathlib
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from typing import Any
from zoneinfo import ZoneInfo

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "shared"))

from PIL import Image, ImageDraw, ImageFont
from pypdf import PdfReader
from reportlab.lib.colors import Color, black, white
from reportlab.lib.utils import ImageReader
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfgen import canvas

from scout_report_visuals import (
    FILLED_FLAG_BOUNDS,
    FILLED_FLAG_PATH,
    filled_flag_metadata,
    visual_state_rgb,
)


SCHEMA_VERSION = 1
GENERATOR_VERSION = "phase2c-shadow-reportlab-refinement-1"
PAGE_WIDTH = 612.0
PAGE_HEIGHT = 792.0
PAGE_SIZE = (PAGE_WIDTH, PAGE_HEIGHT)
DISPLAY_TZ = ZoneInfo("America/New_York")
PDF_IMAGE_MAX_LONG_EDGE = 2000
PDF_IMAGE_JPEG_QUALITY = 80

FLAG_COLOR = (0.827, 0.184, 0.184)
RESOLVED_COLOR = (0.149, 0.678, 0.337)
PRIORITY_COLORS = {
    "critical": (0.827, 0.184, 0.184),
    "high": (0.925, 0.486, 0.156),
    "medium": (0.855, 0.655, 0.128),
    "low": (0.184, 0.482, 0.875),
}
PRIORITY_ORDER = ["critical", "high", "medium", "low"]
PRIORITY_LABELS = {
    "critical": "Critical",
    "high": "High",
    "medium": "Medium",
    "low": "Low",
}

BASE_FOOTER = (
    "This visual property record provides visual documentation only. It does not "
    "constitute an inspection, assessment, certification, or determination of "
    "condition, safety, or compliance. Documentation reflects only what was "
    "visually captured at the time of the site visit."
)
PRIORITY_FOOTER = (
    "Priority levels (Critical, High, Medium, Low) are used solely for "
    "organizational and tracking purposes. They reflect relative visual "
    "prominence and do not represent a professional assessment of condition, "
    "safety, or required action."
)
OFFICIAL_LOGO_PDF = "/Users/brian/Library/CloudStorage/OneDrive-Personal/Scout/New Logos/New Blue Logos/Vector PDF/ScoutLogoBlue.pdf"
OFFICIAL_LOGO_SVG = "/Users/brian/Library/CloudStorage/OneDrive-Personal/Scout/New Logos/New Blue Logos/Vector PDF/Scout Only Logo.svg"


class Phase2BError(RuntimeError):
    pass


def is_not_applicable_error(error: Exception) -> bool:
    return " is not applicable: " in str(error)


@dataclass(frozen=True)
class MediaLookup:
    by_role_shot: dict[tuple[str, str], dict[str, Any]]
    all_hashes: list[dict[str, str]]
    warnings: list[str]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--validation-json", required=True, help="Phase 1B validation JSON.")
    parser.add_argument("--prepared-media-json", required=True, help="Phase 2A PreparedReportMedia JSON.")
    parser.add_argument("--output-dir", required=True, help="Local shadow output directory.")
    parser.add_argument(
        "--report",
        choices=["all", "property", "priority", "comparison"],
        default="all",
        help="Report type to render.",
    )
    parser.add_argument(
        "--report-date",
        help="MM/DD/YYYY report date. Defaults to today in America/New_York.",
    )
    parser.add_argument("--pretty", action="store_true", help="Pretty-print JSON artifacts.")
    parser.add_argument(
        "--historical-oracle",
        action="append",
        default=[],
        help="Historical oracle PDF to render into preview/contact-sheet artifacts.",
    )
    parser.add_argument(
        "--stamped-oracle",
        action="append",
        default=[],
        help="Historical stamped JPG to profile for visual comparison.",
    )
    parser.add_argument(
        "--logo-pdf",
        default=OFFICIAL_LOGO_PDF,
        help="Official SCOUT vector PDF logo asset.",
    )
    parser.add_argument(
        "--logo-svg",
        default=OFFICIAL_LOGO_SVG,
        help="Official SCOUT SVG logo asset used for vector logo rendering.",
    )
    parser.add_argument(
        "--weather-cache",
        help="Deterministic weather cache JSON. Defaults to output-dir/weather_cache.json.",
    )
    parser.add_argument(
        "--allow-weather-fetch",
        action="store_true",
        help="Allow read-only Open-Meteo archive lookup when cache/input has no weather summary.",
    )
    return parser.parse_args()


def stable_json(data: Any, pretty: bool = True) -> str:
    if pretty:
        return json.dumps(data, sort_keys=True, indent=2, separators=(",", ": ")) + "\n"
    return json.dumps(data, sort_keys=True, separators=(",", ":")) + "\n"


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def read_json(path: pathlib.Path) -> Any:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def write_json(path: pathlib.Path, data: Any, pretty: bool) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(stable_json(data, pretty), encoding="utf-8")


def trim(value: Any) -> str | None:
    if value is None:
        return None
    text = str(value).strip()
    return text or None


def boolish(value: Any) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return value != 0
    if value is None:
        return False
    return str(value).strip().lower() in {"1", "true", "yes", "y"}


def parse_date(value: Any) -> dt.datetime | None:
    text = trim(value)
    if not text:
        return None
    try:
        parsed = dt.datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.timezone.utc)
    return parsed.astimezone(dt.timezone.utc)


def local_datetime(value: Any) -> dt.datetime | None:
    parsed = parse_date(value)
    return parsed.astimezone(DISPLAY_TZ) if parsed else None


def file_date(value: Any) -> str:
    parsed = local_datetime(value)
    return parsed.strftime("%Y-%m-%d") if parsed else dt.datetime.now(DISPLAY_TZ).strftime("%Y-%m-%d")


def short_date(value: Any) -> str:
    parsed = local_datetime(value)
    if not parsed:
        return "Unknown"
    return parsed.strftime("%m/%d/%Y")


def display_datetime(value: Any) -> str | None:
    parsed = local_datetime(value)
    if not parsed:
        return trim(value)
    return f"{parsed.strftime('%B')} {parsed.day}, {parsed.year} \u2022 {parsed.strftime('%-I:%M %p')}"


def first_parseable_date(*values: Any) -> str | None:
    for value in values:
        text = trim(value)
        if text and parse_date(text):
            return text
    return None


def month_year(value: Any) -> str | None:
    parsed = local_datetime(value)
    if not parsed:
        return None
    return parsed.strftime("%B %Y")


def sanitize_filename(value: str) -> str:
    replaced = []
    for char in value:
        if ord(char) < 32 or char in {"/", ":", "\\"}:
            replaced.append(" ")
        else:
            replaced.append(char)
    collapsed = re.sub(r"\s+", " ", "".join(replaced)).strip()
    return collapsed or "Item"


def session_descriptor(session: dict[str, Any]) -> str:
    return (
        f"{sanitize_filename(trim(session.get('property_name')) or 'Unknown Property')} - "
        f"{sanitize_filename(trim(session.get('property_street')) or 'Unknown Address')}"
    )


def output_filename(session: dict[str, Any], report_type: str) -> str:
    descriptor = session_descriptor(session)
    date = file_date(session.get("started_at_utc"))
    if report_type == "property":
        suffix = "Property Report"
    elif report_type == "priority":
        suffix = "Priority Report"
    elif report_type == "comparison":
        suffix = "Flagged Comparison Report"
    else:
        raise Phase2BError(f"Unknown report type: {report_type}")
    return f"{descriptor} - {suffix} - {date}.pdf"


def formatted_address(session: dict[str, Any]) -> str:
    direct = trim(session.get("property_address"))
    if direct:
        return direct
    city_state_zip = ", ".join(
        part
        for part in [
            trim(session.get("property_city")),
            " ".join(
                part
                for part in [trim(session.get("property_state")), trim(session.get("property_zip"))]
                if part
            )
            or None,
        ]
        if part
    )
    parts = [trim(session.get("property_street")), city_state_zip or None]
    return ", ".join(part for part in parts if part) or "Unknown address"


def safe_int(value: Any, default: int = 0) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def numeric_suffix(prefix: str, value: Any) -> str | None:
    text = trim(value) or ""
    match = re.match(rf"^{re.escape(prefix)}\s*(\d+)$", text, flags=re.IGNORECASE)
    return match.group(1) if match else None


def friendly_building(value: Any) -> str:
    text = trim(value) or "B1"
    number = numeric_suffix("B", text)
    return f"Building {number}" if number is not None else text


def detail_identifier(shot_key: Any, angle_index: Any) -> str:
    key = (trim(shot_key) or "").upper()
    if re.match(r"^A\d+$", key):
        return key
    return f"A{safe_int(angle_index)}"


def friendly_angle(value: Any) -> str:
    text = trim(value) or "A0"
    number = numeric_suffix("A", text)
    return f"Angle {number}" if number is not None else text


def caption_identity(item: dict[str, Any]) -> str:
    angle = detail_identifier(item.get("shot_key"), item.get("angle_index"))
    parts = [
        friendly_building(item.get("building")),
        trim(item.get("elevation")) or "North",
        trim(item.get("detail_type")) or "General Elevation",
        friendly_angle(angle),
    ]
    return " | ".join(parts).upper()


def section_key(item: dict[str, Any]) -> str:
    return f"{friendly_building(item.get('building')).upper()}|{(trim(item.get('elevation')) or 'Unknown').upper()}"


def slot_key(item: dict[str, Any]) -> str:
    return "|".join(
        [
            (trim(item.get("building")) or "B1").upper(),
            (trim(item.get("elevation")) or "North").upper(),
            (trim(item.get("detail_type")) or "General Elevation").upper(),
            detail_identifier(item.get("shot_key"), item.get("angle_index")).upper(),
        ]
    )


def visual_state(item: dict[str, Any]) -> str:
    if boolish(item.get("is_resolved_in_session")):
        return "resolved"
    if boolish(item.get("is_flagged")):
        return "flagged"
    return "none"


def priority_level(value: Any) -> str:
    text = (trim(value) or "").lower()
    return text if text in PRIORITY_COLORS else "medium"


def detail_sort_priority(value: Any) -> int:
    text = (trim(value) or "General Elevation").upper()
    if text == "OVERVIEW":
        return 0
    if text == "ELEVATION":
        return 1
    return 2


def media_lookup(prepared: dict[str, Any]) -> MediaLookup:
    by_role_shot: dict[tuple[str, str], dict[str, Any]] = {}
    hashes: list[dict[str, str]] = []
    warnings = list(prepared.get("warnings") or [])
    for item in prepared.get("items") or []:
        role = (trim(item.get("role")) or "current").lower()
        shot_id = (trim(item.get("shot_id")) or "").lower()
        if not shot_id:
            warnings.append("prepared_media_item_missing_shot_id")
            continue
        by_role_shot[(role, shot_id)] = item
        hashes.append(
            {
                "role": role,
                "session_id": trim(item.get("session_id")) or "",
                "shot_id": trim(item.get("shot_id")) or "",
                "filename": trim(item.get("prepared_media_filename")) or "",
                "sha256": trim(item.get("deterministic_content_hash")) or "",
            }
        )
        warnings.extend(item.get("warnings") or [])
    hashes.sort(key=lambda row: (row["role"], row["session_id"].lower(), row["shot_id"].lower()))
    return MediaLookup(by_role_shot, hashes, sorted(set(warnings)))


def media_for(lookup: MediaLookup, role: str, shot_id: Any) -> dict[str, Any] | None:
    sid = (trim(shot_id) or "").lower()
    return lookup.by_role_shot.get((role.lower(), sid)) if sid else None


def logo_info(logo_pdf: str | None, logo_svg: str | None) -> dict[str, Any]:
    pdf_path = pathlib.Path(logo_pdf) if logo_pdf else None
    svg_path = pathlib.Path(logo_svg) if logo_svg else None
    info = {
        "source_pdf_path": str(pdf_path) if pdf_path else None,
        "source_pdf_exists": bool(pdf_path and pdf_path.exists()),
        "source_pdf_sha256": sha256_file(pdf_path) if pdf_path and pdf_path.exists() else None,
        "source_svg_path": str(svg_path) if svg_path else None,
        "source_svg_exists": bool(svg_path and svg_path.exists()),
        "source_svg_sha256": sha256_file(svg_path) if svg_path and svg_path.exists() else None,
        "embedding": "official_svg_drawn_as_reportlab_vector_paths",
        "conversion_tool": None,
        "fallback_embedding": "high_resolution_transparent_png_from_pdf",
        "fallback_conversion_tool": "sips shadow conversion" if shutil.which("sips") else "unavailable",
        "transparent_background_required": True,
    }
    return info


def matrix_multiply(lhs: tuple[float, float, float, float, float, float], rhs: tuple[float, float, float, float, float, float]) -> tuple[float, float, float, float, float, float]:
    a1, b1, c1, d1, e1, f1 = lhs
    a2, b2, c2, d2, e2, f2 = rhs
    return (
        a1 * a2 + c1 * b2,
        b1 * a2 + d1 * b2,
        a1 * c2 + c1 * d2,
        b1 * c2 + d1 * d2,
        a1 * e2 + c1 * f2 + e1,
        b1 * e2 + d1 * f2 + f1,
    )


def apply_matrix(matrix: tuple[float, float, float, float, float, float], x: float, y: float) -> tuple[float, float]:
    a, b, c, d, e, f = matrix
    return a * x + c * y + e, b * x + d * y + f


def parse_transform(raw: str | None) -> tuple[float, float, float, float, float, float]:
    current = (1.0, 0.0, 0.0, 1.0, 0.0, 0.0)
    if not raw:
        return current
    for name, args_raw in re.findall(r"([a-zA-Z]+)\(([^)]*)\)", raw):
        values = [float(value) for value in re.findall(r"[-+]?(?:\d*\.\d+|\d+)(?:[eE][-+]?\d+)?", args_raw)]
        if name == "matrix" and len(values) == 6:
            local = tuple(values)  # type: ignore[assignment]
        elif name == "translate":
            tx = values[0] if values else 0.0
            ty = values[1] if len(values) > 1 else 0.0
            local = (1.0, 0.0, 0.0, 1.0, tx, ty)
        elif name == "scale":
            sx = values[0] if values else 1.0
            sy = values[1] if len(values) > 1 else sx
            local = (sx, 0.0, 0.0, sy, 0.0, 0.0)
        else:
            continue
        current = matrix_multiply(current, local)
    return current


def tokenize_svg_path(d: str) -> list[str]:
    return re.findall(r"[MLCZmlcz]|[-+]?(?:\d*\.\d+|\d+)(?:[eE][-+]?\d+)?", d)


def parse_logo_path(d: str, matrix: tuple[float, float, float, float, float, float]) -> list[tuple[str, tuple[float, ...]]]:
    tokens = tokenize_svg_path(d)
    index = 0
    command = ""
    parsed: list[tuple[str, tuple[float, ...]]] = []

    def next_number() -> float:
        nonlocal index
        if index >= len(tokens):
            raise Phase2BError("Unexpected end of SVG path.")
        value = float(tokens[index])
        index += 1
        return value

    while index < len(tokens):
        token = tokens[index]
        if re.match(r"[MLCZmlcz]", token):
            command = token
            index += 1
        if command in {"M", "L"}:
            x, y = apply_matrix(matrix, next_number(), next_number())
            parsed.append((command, (x, y)))
            command = "L" if command == "M" else command
        elif command == "C":
            coords = [next_number() for _ in range(6)]
            p1 = apply_matrix(matrix, coords[0], coords[1])
            p2 = apply_matrix(matrix, coords[2], coords[3])
            p3 = apply_matrix(matrix, coords[4], coords[5])
            parsed.append(("C", (*p1, *p2, *p3)))
        elif command in {"Z", "z"}:
            parsed.append(("Z", ()))
            command = ""
        else:
            raise Phase2BError(f"Unsupported SVG logo path command: {command}")
    return parsed


def load_logo_vector(svg_path: str | None) -> dict[str, Any] | None:
    if not svg_path:
        return None
    path = pathlib.Path(svg_path)
    if not path.exists():
        return None
    root = ET.parse(path).getroot()
    shapes: list[dict[str, Any]] = []

    def walk(node: ET.Element, matrix: tuple[float, float, float, float, float, float]) -> None:
        local = matrix_multiply(matrix, parse_transform(node.attrib.get("transform")))
        if node.tag.endswith("path") and node.attrib.get("d"):
            fill = "#1c2742"
            style = node.attrib.get("style", "")
            match = re.search(r"fill:\s*rgb\((\d+),(\d+),(\d+)\)", style)
            if match:
                fill = "#%02x%02x%02x" % tuple(int(match.group(i)) for i in range(1, 4))
            shapes.append({"commands": parse_logo_path(node.attrib["d"], local), "fill": fill})
        for child in list(node):
            walk(child, local)

    walk(root, (1.0, 0.0, 0.0, 1.0, 0.0, 0.0))
    points = []
    for shape in shapes:
        for command, values in shape["commands"]:
            if command == "C":
                points.extend([(values[0], values[1]), (values[2], values[3]), (values[4], values[5])])
            elif command in {"M", "L"}:
                points.append((values[0], values[1]))
    if not points:
        return None
    xs = [point[0] for point in points]
    ys = [point[1] for point in points]
    return {"shapes": shapes, "bounds": (min(xs), min(ys), max(xs), max(ys))}


def resolve_logo_png(plan: dict[str, Any], work_dir: pathlib.Path, warnings: list[str]) -> str | None:
    logo = plan.get("logo") or {}
    source = pathlib.Path(logo.get("source_pdf_path") or "")
    if not source.exists():
        warnings.append("official_logo_pdf_missing_wordmark_fallback_used")
        return None
    sips = shutil.which("sips")
    if not sips:
        warnings.append("official_logo_conversion_tool_missing_wordmark_fallback_used")
        return None
    raw_png = work_dir / "ScoutLogoBlue.sips.png"
    final_png = work_dir / "ScoutLogoBlue.transparent.png"
    subprocess.run(
        [sips, "-s", "format", "png", str(source), "--out", str(raw_png)],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=60,
    )
    with Image.open(raw_png) as image:
        image = image.convert("RGBA")
        alpha = image.getchannel("A")
        if alpha.getextrema()[0] == 255:
            warnings.append("official_logo_conversion_lost_transparency")
        fallback_scale = 8
        image = image.resize((image.width * fallback_scale, image.height * fallback_scale), Image.Resampling.LANCZOS)
        warnings.append("official_logo_pdf_used_high_resolution_png_fallback_not_final_vector")
        image.save(final_png, "PNG", optimize=False)
    return str(final_png)


def resolve_logo_asset(plan: dict[str, Any], work_dir: pathlib.Path, warnings: list[str]) -> dict[str, Any] | None:
    logo = plan.get("logo") or {}
    try:
        vector = load_logo_vector(logo.get("source_svg_path"))
    except Exception as error:
        warnings.append(f"official_logo_svg_vector_parse_failed:{type(error).__name__}")
        vector = None
    if vector:
        return {"kind": "vector", **vector}
    png = resolve_logo_png(plan, work_dir, warnings)
    return {"kind": "png", "path": png} if png else None


WEATHER_CODE_DESCRIPTIONS = {
    0: "Clear",
    1: "Mostly Clear",
    2: "Partly Cloudy",
    3: "Overcast",
    45: "Fog",
    48: "Fog",
    51: "Drizzle",
    53: "Drizzle",
    55: "Drizzle",
    56: "Drizzle",
    57: "Drizzle",
    61: "Rain",
    63: "Rain",
    65: "Rain",
    66: "Rain",
    67: "Rain",
    71: "Snow",
    73: "Snow",
    75: "Snow",
    77: "Snow",
    80: "Rain Showers",
    81: "Rain Showers",
    82: "Rain Showers",
    85: "Snow Showers",
    86: "Snow Showers",
    95: "Thunderstorm",
    96: "Thunderstorm",
    99: "Thunderstorm",
}


def weather_code_description(code: Any) -> str:
    try:
        return WEATHER_CODE_DESCRIPTIONS.get(int(code), "Variable Conditions")
    except (TypeError, ValueError):
        return "Variable Conditions"


def load_weather_cache(path: pathlib.Path | None, warnings: list[str]) -> dict[str, Any]:
    if not path or not path.exists():
        return {}
    try:
        return read_json(path)
    except Exception:
        warnings.append("weather_cache_unreadable")
        return {}


def write_weather_cache(path: pathlib.Path | None, cache: dict[str, Any], warnings: list[str], pretty: bool) -> None:
    if not path:
        return
    try:
        write_json(path, cache, pretty)
    except Exception:
        warnings.append("weather_cache_write_failed")


def weather_anchor(validation: dict[str, Any]) -> tuple[float, float, dt.datetime] | None:
    session = validation.get("inputs", {}).get("session") or {}
    shots = validation.get("inputs", {}).get("ordered_shots") or []
    target = None
    for shot in shots:
        target = target or parse_date(shot.get("captured_at_utc"))
        try:
            latitude = float(shot.get("latitude"))
            longitude = float(shot.get("longitude"))
        except (TypeError, ValueError):
            continue
        shot_date = parse_date(shot.get("captured_at_utc")) or target
        if shot_date:
            return latitude, longitude, shot_date
    fallback_date = target or parse_date(session.get("started_at_utc"))
    return None if not fallback_date else None


def weather_cache_key(latitude: float, longitude: float, target: dt.datetime) -> str:
    day = target.astimezone(DISPLAY_TZ).strftime("%Y-%m-%d")
    return f"{latitude:.6f},{longitude:.6f},{day}"


def weather_summary_from_input(validation: dict[str, Any]) -> dict[str, Any] | None:
    candidates = [
        validation.get("inputs", {}).get("weather"),
        validation.get("inputs", {}).get("session", {}).get("weather"),
        validation.get("weather"),
    ]
    for candidate in candidates:
        if isinstance(candidate, str) and trim(candidate):
            return {"summary": trim(candidate), "source": "ReportInput"}
        if isinstance(candidate, dict):
            summary = trim(candidate.get("summary") or candidate.get("weather_summary") or candidate.get("conditions"))
            if summary:
                return {"summary": summary, "source": trim(candidate.get("source")) or "ReportInput"}
    return None


def fetch_open_meteo_weather_summary(latitude: float, longitude: float, target: dt.datetime) -> dict[str, Any]:
    local_target = target.astimezone(DISPLAY_TZ)
    service_day = local_target.strftime("%Y-%m-%d")
    query = urllib.parse.urlencode(
        {
            "latitude": f"{latitude:.6f}",
            "longitude": f"{longitude:.6f}",
            "start_date": service_day,
            "end_date": service_day,
            "hourly": "temperature_2m,weather_code,wind_speed_10m,precipitation",
            "temperature_unit": "fahrenheit",
            "wind_speed_unit": "mph",
            "precipitation_unit": "inch",
            "timezone": "America/New_York",
        }
    )
    url = f"https://archive-api.open-meteo.com/v1/archive?{query}"
    request = urllib.request.Request(url, headers={"Accept": "application/json"})
    with urllib.request.urlopen(request, timeout=9) as response:
        payload = json.loads(response.read().decode("utf-8"))
    hourly = payload.get("hourly") or {}
    times = hourly.get("time") or []
    if not times:
        raise Phase2BError("Open-Meteo response contained no hourly weather times.")
    indexed = []
    for index, raw_time in enumerate(times):
        try:
            parsed = dt.datetime.fromisoformat(raw_time).replace(tzinfo=DISPLAY_TZ)
        except ValueError:
            continue
        indexed.append((abs((parsed - local_target).total_seconds()), index))
    if not indexed:
        raise Phase2BError("Open-Meteo response contained no parseable hourly weather times.")
    _, nearest_index = min(indexed, key=lambda row: row[0])

    def hourly_value(name: str) -> Any:
        values = hourly.get(name) or []
        return values[nearest_index] if nearest_index < len(values) else None

    parts = [weather_code_description(hourly_value("weather_code"))]
    temperature = hourly_value("temperature_2m")
    wind = hourly_value("wind_speed_10m")
    precipitation = hourly_value("precipitation")
    if isinstance(temperature, (int, float)):
        parts.append(f"{temperature:.0f}\u00b0F")
    if isinstance(wind, (int, float)):
        parts.append(f"Wind {wind:.0f} mph")
    if isinstance(precipitation, (int, float)) and precipitation > 0:
        parts.append(f"Precipitation {precipitation:.2f} in")
    return {
        "summary": " | ".join(parts),
        "source": "Open-Meteo archive",
        "latitude": latitude,
        "longitude": longitude,
        "target_date_utc": target.isoformat(),
        "service_day": service_day,
        "nearest_hour_local": times[nearest_index],
        "provider_url": url,
    }


def resolve_weather_summary(
    validation: dict[str, Any],
    cache_path: pathlib.Path | None,
    allow_fetch: bool,
    warnings: list[str],
    pretty: bool,
) -> dict[str, Any]:
    input_summary = weather_summary_from_input(validation)
    if input_summary:
        return {**input_summary, "available": True, "fetched": False, "cached": False}
    anchor = weather_anchor(validation)
    if not anchor:
        warnings.append("weather_unavailable_no_shot_coordinates")
        return {"available": False, "summary": None, "source": None, "fetched": False, "cached": False}
    latitude, longitude, target = anchor
    key = weather_cache_key(latitude, longitude, target)
    cache = load_weather_cache(cache_path, warnings)
    if key in cache and isinstance(cache[key], dict):
        return {**cache[key], "available": bool(cache[key].get("summary")), "fetched": False, "cached": True}
    if not allow_fetch:
        warnings.append("weather_fetch_disabled_no_cached_weather")
        return {
            "available": False,
            "summary": None,
            "source": None,
            "latitude": latitude,
            "longitude": longitude,
            "service_day": target.astimezone(DISPLAY_TZ).strftime("%Y-%m-%d"),
            "fetched": False,
            "cached": False,
        }
    try:
        fetched = fetch_open_meteo_weather_summary(latitude, longitude, target)
    except (urllib.error.URLError, TimeoutError, Phase2BError, json.JSONDecodeError) as error:
        warnings.append(f"weather_fetch_failed:{type(error).__name__}")
        return {
            "available": False,
            "summary": None,
            "source": "Open-Meteo archive",
            "latitude": latitude,
            "longitude": longitude,
            "service_day": target.astimezone(DISPLAY_TZ).strftime("%Y-%m-%d"),
            "fetched": False,
            "cached": False,
        }
    cache[key] = fetched
    write_weather_cache(cache_path, cache, warnings, pretty)
    return {**fetched, "available": True, "fetched": True, "cached": False}


def image_size_from_media(media: dict[str, Any] | None) -> tuple[float, float] | None:
    if not media:
        return None
    width = media.get("prepared_width") or media.get("source_width")
    height = media.get("prepared_height") or media.get("source_height")
    try:
        width_f = float(width)
        height_f = float(height)
    except (TypeError, ValueError):
        return None
    if width_f <= 0 or height_f <= 0:
        return None
    return width_f, height_f


def aspect_fit_rect(image_size: tuple[float, float], container: dict[str, float]) -> dict[str, float]:
    width, height = image_size
    scale = min(container["width"] / width, container["height"] / height)
    fitted_w = width * scale
    fitted_h = height * scale
    return {
        "x": container["x"] + (container["width"] - fitted_w) / 2.0,
        "y": container["y"] + (container["height"] - fitted_h) / 2.0,
        "width": fitted_w,
        "height": fitted_h,
    }


def centered_rect_like(reference: dict[str, float], container: dict[str, float]) -> dict[str, float]:
    width = min(reference["width"], container["width"])
    height = min(reference["height"], container["height"])
    return {
        "x": container["x"] + (container["width"] - width) / 2.0,
        "y": container["y"] + (container["height"] - height) / 2.0,
        "width": width,
        "height": height,
    }


def body_slots(count: int, include_header: bool = False) -> list[dict[str, dict[str, float]]]:
    outer_margin = 18.0
    footer_height = 82.0
    header_height = 20.0 if include_header else 0.0
    logo_header_reserve = 34.0
    photo_stack_vertical_offset = 28.0
    photo_caption_gap = 8.0
    metadata_height = 66.0
    slot_gap = 2.0
    content_top = PAGE_HEIGHT - outer_margin - header_height - logo_header_reserve - photo_stack_vertical_offset
    content_bottom = outer_margin + footer_height - photo_stack_vertical_offset
    content_height = content_top - content_bottom
    slot_height = (content_height - slot_gap) / 2.0
    slot_width = PAGE_WIDTH - (outer_margin * 2.0)
    slots = []
    for index in range(count):
        slot_top = content_top - index * (slot_height + slot_gap)
        caption_rect = {
            "x": outer_margin,
            "y": slot_top - slot_height,
            "width": slot_width,
            "height": metadata_height,
        }
        photo_rect = {
            "x": outer_margin,
            "y": caption_rect["y"] + metadata_height + photo_caption_gap,
            "width": slot_width,
            "height": slot_height - metadata_height - photo_caption_gap,
        }
        slots.append({"photo_available_rect": photo_rect, "caption_rect": caption_rect})
    return slots


def index_page_plans(lines: list[dict[str, Any]], line_offset: float = 0.0) -> list[list[dict[str, Any]]]:
    if not lines:
        return []
    left_margin = 64.0
    right_margin = 64.0
    top_y = PAGE_HEIGHT - 106.0
    bottom_y = 96.0
    usable_width = PAGE_WIDTH - left_margin - right_margin
    pages: list[list[dict[str, Any]]] = []
    placed: list[dict[str, Any]] = []
    cursor_y = top_y
    for line in lines:
        kind = line["kind"]
        if kind == "sectionHeader":
            line_height = 18.0
            padding_before = 14.0 if not placed else 12.0
            line_spacing = 4.0
        elif kind == "retiredSpacer":
            line_height = 6.0
            padding_before = 0.0
            line_spacing = 6.0
        elif kind == "retiredNote":
            line_height = 15.0
            padding_before = 0.0
            line_spacing = 2.0
        else:
            line_height = 15.0
            padding_before = 0.0
            line_spacing = 3.0
        if cursor_y - padding_before - line_height < bottom_y:
            if placed:
                pages.append(placed)
                placed = []
            cursor_y = top_y
        rect = {
            "x": left_margin,
            "y": cursor_y - padding_before - line_height - line_offset,
            "width": usable_width,
            "height": line_height,
        }
        placed.append({**line, "rect": rect})
        cursor_y -= padding_before + line_height + line_spacing
    if placed:
        pages.append(placed)
    return pages


def property_entries(validation: dict[str, Any], lookup: MediaLookup) -> list[dict[str, Any]]:
    shots = validation.get("inputs", {}).get("ordered_shots") or []
    shot_by_id = {(trim(shot.get("shot_id")) or "").lower(): shot for shot in shots}
    source_entries = validation.get("inputs", {}).get("property_report_entries") or []
    result: list[dict[str, Any]] = []
    for source in source_entries:
        kind = trim(source.get("kind")) or "photo"
        shot = shot_by_id.get((trim(source.get("shot_id")) or "").lower(), {})
        entry = {**source, **shot, "kind": kind}
        media = media_for(lookup, "current", entry.get("shot_id"))
        entry["media"] = media
        entry["media_path"] = trim(media.get("temporary_prepared_path")) if media else None
        entry["caption"] = caption_identity(entry)
        entry["visual_state"] = visual_state(entry)
        entry["captured_at_display"] = " " if kind == "skipped" else (display_datetime(entry.get("captured_at_utc")) or "Unknown")
        entry["slot_key"] = slot_key(entry)
        result.append(entry)
    order_keys = []
    for shot in shots:
        key = section_key(shot)
        if key not in order_keys:
            order_keys.append(key)

    def sort_key(entry: dict[str, Any]) -> tuple[Any, ...]:
        key = section_key(entry)
        section_index = order_keys.index(key) if key in order_keys else 999999
        return (
            section_index,
            detail_sort_priority(entry.get("detail_type")),
            (trim(entry.get("detail_type")) or "General Elevation").upper(),
            safe_int(entry.get("angle_index")),
            1 if entry.get("kind") == "skipped" else 0,
            parse_date(entry.get("captured_at_utc")) or dt.datetime.max.replace(tzinfo=dt.timezone.utc),
            trim(entry.get("original_filename")) or "",
        )

    return sorted(result, key=sort_key)


def grouped_property_sections(entries: list[dict[str, Any]], validation: dict[str, Any]) -> list[dict[str, Any]]:
    grouped: dict[str, list[dict[str, Any]]] = {}
    meta: dict[str, tuple[str, str]] = {}
    for entry in entries:
        key = section_key(entry)
        grouped.setdefault(key, []).append(entry)
        meta.setdefault(key, (friendly_building(entry.get("building")), trim(entry.get("elevation")) or "Unknown"))
    retired_notes_by_key: dict[str, list[str]] = {}
    for note in validation.get("guided_placeholders", {}).get("retired_notes") or []:
        if isinstance(note, dict):
            key = section_key(note)
            text = trim(note.get("text")) or trim(note.get("note")) or stable_json(note, False).strip()
        else:
            key = "BUILDING|UNKNOWN"
            text = str(note)
        retired_notes_by_key.setdefault(key, []).append(text)
    keys = list(grouped.keys())
    for key in retired_notes_by_key:
        if key not in keys:
            keys.append(key)
            meta.setdefault(key, ("Building", "Unknown"))
    sections = []
    next_page = 0
    for key in keys:
        section_entries = grouped.get(key, [])
        title = f"{meta[key][0]} {meta[key][1]} Elevation"
        chunks = [section_entries[i : i + 2] for i in range(0, len(section_entries), 2)]
        sections.append(
            {
                "key": key,
                "title": title,
                "entries": section_entries,
                "retired_notes": retired_notes_by_key.get(key, []),
                "chunks": chunks,
                "relative_start_chunk": next_page,
            }
        )
        next_page += len(chunks)
    return sections


def add_photo_slots_to_page(page: dict[str, Any], entries: list[dict[str, Any]]) -> None:
    slots = body_slots(len(entries))
    rendered_slots = []
    for slot, entry in zip(slots, entries):
        media = entry.get("media")
        fitted = None
        size = image_size_from_media(media)
        if size:
            fitted = aspect_fit_rect(size, slot["photo_available_rect"])
        rendered_slots.append(
            {
                **slot,
                "entry": compact_entry(entry),
                "image_rect": fitted,
                "placeholder_reason": trim(entry.get("skip_reason")) or ("Image unavailable" if not media else None),
            }
        )
    page["slots"] = rendered_slots


def compact_entry(entry: dict[str, Any]) -> dict[str, Any]:
    keys = [
        "kind",
        "shot_id",
        "session_id",
        "building",
        "elevation",
        "detail_type",
        "angle_index",
        "shot_key",
        "caption",
        "captured_at_utc",
        "session_date_utc",
        "captured_at_display",
        "flagged_reason",
        "priority",
        "normalized_priority",
        "visual_state",
        "media_path",
        "original_filename",
        "suppress_session_label",
    ]
    return {key: entry.get(key) for key in keys if key in entry}


def build_property_plan(validation: dict[str, Any], lookup: MediaLookup, report_date: str, logo: dict[str, Any], weather: dict[str, Any]) -> dict[str, Any]:
    session = validation.get("inputs", {}).get("session") or {}
    entries = property_entries(validation, lookup)
    sections = grouped_property_sections(entries, validation)
    assumed_index_pages = 1
    index_pages: list[list[dict[str, Any]]] = []
    section_page_ranges: list[dict[str, Any]] = []
    for _ in range(3):
        start_page = 3 + assumed_index_pages
        page_cursor = start_page
        lines: list[dict[str, Any]] = []
        section_page_ranges = []
        for section in sections:
            chunk_count = len(section["chunks"])
            section_start = page_cursor
            section_end = page_cursor + max(chunk_count - 1, 0)
            section_page_ranges.append({"key": section["key"], "start": section_start, "end": section_end})
            if section["entries"]:
                header = f"{section['title']} pages {section_start}-{section_end}"
            else:
                header = section["title"]
            lines.append({"kind": "sectionHeader", "text": header, "page_number": None, "is_flagged": False, "visual_state": "none"})
            for index, entry in enumerate(section["entries"]):
                page_number = section_start + index // 2
                text = entry["caption"] + (" | Resolved" if entry["visual_state"] == "resolved" else "")
                lines.append(
                    {
                        "kind": "photoItem",
                        "text": text,
                        "page_number": page_number,
                        "is_flagged": entry["visual_state"] != "none",
                        "visual_state": entry["visual_state"],
                    }
                )
            if section["retired_notes"]:
                lines.append({"kind": "retiredSpacer", "text": "", "page_number": None, "is_flagged": False, "visual_state": "none"})
                for note in section["retired_notes"]:
                    lines.append({"kind": "retiredNote", "text": note, "page_number": None, "is_flagged": False, "visual_state": "none"})
            page_cursor += chunk_count
        index_pages = index_page_plans(lines)
        resolved = max(1, len(index_pages))
        if resolved == assumed_index_pages:
            break
        assumed_index_pages = resolved
    if not index_pages:
        index_pages = [[]]
    cover_entry = next((entry for entry in entries if entry.get("kind") != "skipped" and entry.get("media_path")), None)
    pages = [
        {"number": 1, "kind": "cover", "title": "Visual Property Record", "cover_media_path": cover_entry.get("media_path") if cover_entry else None},
        {"number": 2, "kind": "scope", "footer_extra": PRIORITY_FOOTER},
    ]
    page_number = 3
    for lines in index_pages:
        pages.append({"number": page_number, "kind": "index", "supporting_line": None, "lines": lines})
        page_number += 1
    for section in sections:
        for chunk in section["chunks"]:
            page = {"number": page_number, "kind": "photo", "section_key": section["key"]}
            add_photo_slots_to_page(page, chunk)
            pages.append(page)
            page_number += 1
    return make_plan("property", session, validation, lookup, report_date, pages, logo, weather)


def build_priority_plan(validation: dict[str, Any], lookup: MediaLookup, report_date: str, logo: dict[str, Any], weather: dict[str, Any]) -> dict[str, Any]:
    session = validation.get("inputs", {}).get("session") or {}
    shots = validation.get("inputs", {}).get("ordered_shots") or []
    entries = []
    for shot in shots:
        if not boolish(shot.get("is_flagged")):
            continue
        media = media_for(lookup, "current", shot.get("shot_id"))
        level = priority_level(shot.get("normalized_priority") or shot.get("priority"))
        entry = {
            **shot,
            "kind": "photo",
            "media": media,
            "media_path": trim(media.get("temporary_prepared_path")) if media else None,
            "caption": caption_identity(shot),
            "visual_state": "flagged",
            "captured_at_display": display_datetime(shot.get("captured_at_utc")) or "Unknown",
            "normalized_priority": level,
        }
        entries.append(entry)
    entries.sort(
        key=lambda entry: (
            PRIORITY_ORDER.index(entry["normalized_priority"]),
            entry["caption"].lower(),
            parse_date(entry.get("captured_at_utc")) or dt.datetime.max.replace(tzinfo=dt.timezone.utc),
            trim(entry.get("original_filename")) or "",
        )
    )
    sections = []
    for level in PRIORITY_ORDER:
        level_entries = [entry for entry in entries if entry["normalized_priority"] == level]
        if not level_entries:
            continue
        sections.append({"priority": level, "entries": level_entries, "chunks": [level_entries[i : i + 2] for i in range(0, len(level_entries), 2)]})
    if not entries:
        raise Phase2BError("Priority report is not applicable: no flagged shots.")
    assumed_index_pages = 1
    index_pages: list[list[dict[str, Any]]] = []
    section_ranges: list[dict[str, Any]] = []
    for _ in range(3):
        content_start = 3 + assumed_index_pages
        cursor = content_start
        lines = []
        section_ranges = []
        for section in sections:
            section_page = cursor
            cursor += 1
            chunk_pages = list(range(cursor, cursor + len(section["chunks"])))
            cursor += len(section["chunks"])
            start = section_page
            end = chunk_pages[-1] if chunk_pages else section_page
            section_ranges.append({"priority": section["priority"], "section_page": section_page, "chunk_pages": chunk_pages, "start": start, "end": end})
            label = PRIORITY_LABELS[section["priority"]]
            header = f"{label} (Priority Group) pages {start}-{end}" if chunk_pages else f"{label} (Priority Group) page {section_page}"
            lines.append({"kind": "sectionHeader", "text": header, "page_number": None, "is_flagged": False, "visual_state": "none"})
            for index, entry in enumerate(section["entries"]):
                page_num = chunk_pages[index // 2] if chunk_pages else section_page
                lines.append(
                    {
                        "kind": "photoItem",
                        "text": f"{entry['caption']} | {label} (Priority)",
                        "page_number": page_num,
                        "is_flagged": True,
                        "visual_state": "flagged",
                    }
                )
        index_pages = index_page_plans(lines, line_offset=28.0)
        resolved = max(1, len(index_pages))
        if resolved == assumed_index_pages:
            break
        assumed_index_pages = resolved
    cover_shot = next((shot for shot in shots if media_for(lookup, "current", shot.get("shot_id"))), None)
    cover_media = media_for(lookup, "current", cover_shot.get("shot_id")) if cover_shot else None
    pages = [
        {
            "number": 1,
            "kind": "cover",
            "title": "PRIORITY REPORT",
            "subtitle": "Organized Summary of Documented Observations",
            "supporting_line": "Items are grouped by priority level for tracking and visibility only.",
            "cover_media_path": trim(cover_media.get("temporary_prepared_path")) if cover_media else None,
        },
        {"number": 2, "kind": "scope", "footer_extra": PRIORITY_FOOTER},
    ]
    number = 3
    for lines in index_pages:
        pages.append(
            {
                "number": number,
                "kind": "index",
                "supporting_line": "Priority levels indicate relative visibility and tracking order only.",
                "lines": lines,
            }
        )
        number += 1
    ranges_by_priority = {row["priority"]: row for row in section_ranges}
    for section in sections:
        ranges = ranges_by_priority[section["priority"]]
        pages.append(
            {
                "number": number,
                "kind": "priority_section",
                "priority": section["priority"],
                "entry_count": len(section["entries"]),
            }
        )
        number += 1
        for chunk in section["chunks"]:
            page = {"number": number, "kind": "priority_photo", "priority": section["priority"]}
            add_photo_slots_to_page(page, chunk)
            pages.append(page)
            number += 1
    return make_plan("priority", session, validation, lookup, report_date, pages, logo, weather)


def load_validation_by_session(validation_lookup_dir: pathlib.Path | None, session_id: str | None) -> dict[str, Any] | None:
    if not validation_lookup_dir or not session_id:
        return None
    target = session_id.lower()
    direct = validation_lookup_dir / f"validation_{target}.json"
    candidates = [direct] if direct.exists() else []
    candidates.extend(path for path in validation_lookup_dir.glob("validation_*.json") if path not in candidates)
    for path in candidates:
        try:
            value = read_json(path)
        except Exception:
            continue
        found = trim(value.get("session_id") or value.get("inputs", {}).get("session", {}).get("session_id"))
        if found and found.lower() == target:
            return value
    return None


def previous_shot_metadata(validation_lookup_dir: pathlib.Path | None, previous_session_id: str | None, previous_shot_id: str | None) -> tuple[dict[str, Any] | None, dict[str, Any] | None]:
    previous_validation = load_validation_by_session(validation_lookup_dir, previous_session_id)
    if not previous_validation:
        return None, None
    session = previous_validation.get("inputs", {}).get("session") or {}
    shots = previous_validation.get("inputs", {}).get("ordered_shots") or []
    wanted = (previous_shot_id or "").lower()
    shot = next(((candidate or {}) for candidate in shots if (trim(candidate.get("shot_id")) or "").lower() == wanted), None)
    return session, shot


def previous_session_date_source(
    item: dict[str, Any],
    previous_session: dict[str, Any] | None,
    previous_media: dict[str, Any] | None,
) -> str | None:
    session = previous_session or {}
    media = previous_media or {}
    return first_parseable_date(
        item.get("previous_session_completed_at_utc"),
        item.get("previous_session_exported_at_utc"),
        item.get("previous_session_ended_at_utc"),
        session.get("completed_at_utc"),
        session.get("exported_at_utc"),
        session.get("ended_at_utc"),
        media.get("session_completed_at_utc"),
        media.get("session_exported_at_utc"),
        media.get("session_ended_at_utc"),
    )


def previous_captured_date_source(
    item: dict[str, Any],
    previous_shot: dict[str, Any] | None,
    previous_media: dict[str, Any] | None,
) -> str | None:
    shot = previous_shot or {}
    media = previous_media or {}
    return first_parseable_date(
        item.get("previous_captured_at_utc"),
        shot.get("captured_at_utc"),
        media.get("captured_at_utc"),
    )


def build_comparison_plan(
    validation: dict[str, Any],
    lookup: MediaLookup,
    report_date: str,
    logo: dict[str, Any],
    weather: dict[str, Any],
    validation_lookup_dir: pathlib.Path | None = None,
) -> dict[str, Any]:
    session = validation.get("inputs", {}).get("session") or {}
    shots = validation.get("inputs", {}).get("ordered_shots") or []
    shot_by_id = {(trim(shot.get("shot_id")) or "").lower(): shot for shot in shots}
    comparison_items = validation.get("comparisons", {}).get("items") or []
    entries = []
    comparison_warnings: list[str] = []
    for item in comparison_items:
        current = shot_by_id.get((trim(item.get("current_shot_id")) or "").lower())
        if not current:
            continue
        current_media = media_for(lookup, "current", current.get("shot_id"))
        previous_media = media_for(lookup, "previous", item.get("previous_shot_id"))
        previous_session_id = trim(item.get("previous_session_id"))
        previous_shot_id = trim(item.get("previous_shot_id"))
        previous_session, previous_shot = previous_shot_metadata(validation_lookup_dir, previous_session_id, previous_shot_id)
        previous_session_date = previous_session_date_source(item, previous_session, previous_media)
        previous_captured_date = previous_captured_date_source(item, previous_shot, previous_media)
        previous_display_date = previous_session_date or previous_captured_date
        has_previous_photo = bool(previous_shot_id or previous_media)
        if previous_shot_id and not previous_shot and not previous_display_date:
            comparison_warnings.append("previous_comparison_metadata_unavailable_in_local_validation_lookup")
        previous_visual_state = (
            visual_state(previous_shot)
            if previous_shot
            else trim(previous_media.get("flag_resolved_state_applied")) if previous_media else "none"
        )
        previous_stub = {
            "session_id": previous_session_id,
            "shot_id": previous_shot_id,
            "building": (previous_shot or {}).get("building") or current.get("building"),
            "elevation": (previous_shot or {}).get("elevation") or current.get("elevation"),
            "detail_type": (previous_shot or {}).get("detail_type") or current.get("detail_type"),
            "angle_index": (previous_shot or {}).get("angle_index") or current.get("angle_index"),
            "shot_key": (previous_shot or {}).get("shot_key") or current.get("shot_key"),
            "visual_state": previous_visual_state,
            "flagged_reason": (previous_shot or {}).get("flagged_reason"),
            "captured_at_utc": previous_captured_date,
            "session_date_utc": previous_session_date,
        }
        entries.append(
            {
                "current": {
                    **current,
                    "caption": caption_identity(current),
                    "visual_state": visual_state(current),
                    "media": current_media,
                    "media_path": trim(current_media.get("temporary_prepared_path")) if current_media else None,
                    "captured_at_display": display_datetime(current.get("captured_at_utc")) or "Unknown",
                    "month_year": month_year(current.get("captured_at_utc")) or "Unknown",
                },
                "previous": {
                    **previous_stub,
                    "caption": caption_identity(previous_stub),
                    "media": previous_media,
                    "media_path": trim(previous_media.get("temporary_prepared_path")) if previous_media else None,
                    "captured_at_display": display_datetime(previous_display_date) or ("Unknown" if previous_shot_id else "None"),
                    "month_year": month_year(previous_display_date) or ("Unknown" if previous_shot_id else "None"),
                    "missing_reason": None if previous_media else ("IMAGE UNAVAILABLE" if previous_shot_id else "No previous session photo available"),
                    "suppress_session_label": not has_previous_photo,
                },
                "source_selection": item,
                "has_previous_photo": has_previous_photo,
            }
        )
    if not entries:
        raise Phase2BError("Flagged comparison report is not applicable: no comparison entries.")
    entries.sort(
        key=lambda entry: (
            friendly_building(entry["current"].get("building")).upper(),
            (trim(entry["current"].get("elevation")) or "Unknown").upper(),
            (trim(entry["current"].get("detail_type")) or "General Elevation").upper(),
            safe_int(entry["current"].get("angle_index")),
            entry["current"].get("captured_at_utc") or "",
            entry["current"].get("original_filename") or "",
        )
    )
    lines = [
        {"kind": "sectionHeader", "text": "Flagged Items", "page_number": None, "is_flagged": False, "visual_state": "none"}
    ]
    for index, entry in enumerate(entries):
        current = entry["current"]
        previous = entry["previous"]
        resolved_suffix = " | Resolved" if current["visual_state"] == "resolved" else ""
        text = f"{current['caption']} | {current['month_year']} vs {previous['month_year']}{resolved_suffix}"
        lines.append({"kind": "photoItem", "text": text, "page_number": 4 + index, "is_flagged": True, "visual_state": current["visual_state"]})
    index_pages = index_page_plans(lines)
    if not index_pages:
        index_pages = [[]]
    cover_shot = next((shot for shot in shots if not boolish(shot.get("is_flagged")) and media_for(lookup, "current", shot.get("shot_id"))), None)
    cover_media = media_for(lookup, "current", cover_shot.get("shot_id")) if cover_shot else None
    pages = [
        {"number": 1, "kind": "cover", "title": "Flagged Comparison Report", "cover_media_path": trim(cover_media.get("temporary_prepared_path")) if cover_media else None},
        {"number": 2, "kind": "scope", "footer_extra": PRIORITY_FOOTER},
    ]
    number = 3
    for page_lines in index_pages:
        pages.append({"number": number, "kind": "index", "supporting_line": None, "lines": page_lines})
        number += 1
    for entry in entries:
        slots = []
        two_up_slots = body_slots(2)
        current_media = entry["current"].get("media")
        current_image_size = image_size_from_media(current_media)
        current_frame = aspect_fit_rect(current_image_size, two_up_slots[0]["photo_available_rect"]) if current_image_size else None
        for index, role_name in enumerate(["current", "previous"]):
            item = entry[role_name]
            base = two_up_slots[index]
            media = item.get("media")
            fitted = aspect_fit_rect(image_size_from_media(media), base["photo_available_rect"]) if image_size_from_media(media) else None
            if role_name == "current":
                fitted = current_frame
            elif not entry.get("has_previous_photo") and not media and current_frame:
                fitted = centered_rect_like(current_frame, base["photo_available_rect"])
            slots.append(
                {
                    **base,
                    "role": role_name,
                    "entry": compact_entry(item),
                    "image_rect": fitted,
                    "placeholder_reason": item.get("missing_reason") or ("IMAGE UNAVAILABLE" if not media else None),
                }
            )
        pages.append({"number": number, "kind": "comparison_photo", "slots": slots})
        number += 1
    if comparison_warnings:
        weather = {**weather, "warnings": sorted(set(list(weather.get("warnings") or []) + comparison_warnings))}
    plan = make_plan("comparison", session, validation, lookup, report_date, pages, logo, weather)
    return plan


def make_plan(
    report_type: str,
    session: dict[str, Any],
    validation: dict[str, Any],
    lookup: MediaLookup,
    report_date: str,
    pages: list[dict[str, Any]],
    logo: dict[str, Any],
    weather: dict[str, Any],
) -> dict[str, Any]:
    plan = {
        "schema_version": SCHEMA_VERSION,
        "phase": "ScoutCapture Phase 2C ReportPlan",
        "generator_version": GENERATOR_VERSION,
        "report_type": report_type,
        "output_filename": output_filename(session, report_type),
        "session_id": validation.get("session_id") or session.get("session_id"),
        "source_snapshot_id": validation.get("source_snapshot_id"),
        "session": {
            "property_name": session.get("property_name"),
            "property_address": formatted_address(session),
            "started_at_utc": session.get("started_at_utc"),
            "ended_at_utc": session.get("ended_at_utc"),
            "date_of_service": short_date(session.get("started_at_utc")),
            "time_window": time_window(validation),
            "report_reference_id": session.get("session_id"),
            "report_date": report_date,
            "weather_summary": weather.get("summary") if weather.get("available") else None,
            "weather_source": weather.get("source") if weather.get("available") else None,
        },
        "weather": weather,
        "page_size": {"width": PAGE_WIDTH, "height": PAGE_HEIGHT, "units": "points"},
        "logo": logo,
        "layout": {
            "outer_margin": 18,
            "content_margin": 64,
            "cover_horizontal_margin": 72,
            "image_corner_radius": 12,
            "visual_state_border_width": 3,
            "visual_state_border_outset": 0.5,
            "photo_body": {
                "footer_height": 82,
                "logo_header_reserve": 34,
                "photo_stack_vertical_offset": 28,
                "photo_caption_gap": 8,
                "metadata_height": 66,
                "slot_gap": 2,
            },
            "pdf_time_image_optimization": {
                "max_long_edge": PDF_IMAGE_MAX_LONG_EDGE,
                "jpeg_quality": PDF_IMAGE_JPEG_QUALITY,
            },
            "colors": {
                "flagged": FLAG_COLOR,
                "resolved": RESOLVED_COLOR,
                "priority": PRIORITY_COLORS,
            },
            "flag_visual_language": {
                "shared_module": "web-contract/shared/scout_report_visuals.py",
                "glyph": "Google Material Icons filled flag",
                "metadata": filled_flag_metadata(),
                "flagged_rgb": visual_state_rgb("flagged"),
                "resolved_rgb": visual_state_rgb("resolved"),
                "used_by": ["Phase 2A stamped image overlay", "Phase 2C PDF page markers"],
            },
        },
        "prepared_media_hashes": lookup.all_hashes,
        "warnings": sorted(set(list(lookup.warnings) + list(weather.get("warnings") or []))),
        "pages": pages,
    }
    plan["report_plan_sha256"] = sha256_bytes(stable_json({k: v for k, v in plan.items() if k != "report_plan_sha256"}, False).encode("utf-8"))
    return plan


def time_window(validation: dict[str, Any]) -> str:
    shots = validation.get("inputs", {}).get("ordered_shots") or []
    shot_dates = [local_datetime(shot.get("captured_at_utc")) for shot in shots]
    shot_dates = [value for value in shot_dates if value is not None]
    session = validation.get("inputs", {}).get("session") or {}
    first = shot_dates[0] if shot_dates else local_datetime(session.get("started_at_utc"))
    last = shot_dates[-1] if shot_dates else local_datetime(session.get("ended_at_utc") or session.get("started_at_utc"))
    if not first:
        return "Unknown"
    first_text = first.strftime("%-I:%M %p")
    if not last:
        return first_text
    last_text = last.strftime("%-I:%M %p")
    return first_text if first_text == last_text else f"{first_text} to {last_text}"


def color_tuple(rgb: tuple[float, float, float]) -> Color:
    return Color(rgb[0], rgb[1], rgb[2], 1)


def text_width(text: str, font: str, size: float) -> float:
    return pdfmetrics.stringWidth(text, font, size)


def draw_text(
    c: canvas.Canvas,
    text: str,
    rect: dict[str, float],
    font: str = "Helvetica",
    size: float = 10,
    fill: Color = black,
    align: str = "left",
) -> None:
    c.saveState()
    c.setFont(font, size)
    c.setFillColor(fill)
    y = rect["y"] + max(0, (rect["height"] - size) / 2.0)
    if align == "center":
        c.drawCentredString(rect["x"] + rect["width"] / 2.0, y, text)
    elif align == "right":
        c.drawRightString(rect["x"] + rect["width"], y, text)
    else:
        c.drawString(rect["x"], y, text)
    c.restoreState()


def wrap_lines(text: str, font: str, size: float, max_width: float) -> list[str]:
    words = text.split()
    lines: list[str] = []
    current = ""
    for word in words:
        candidate = f"{current} {word}".strip()
        if not current or text_width(candidate, font, size) <= max_width:
            current = candidate
        else:
            lines.append(current)
            current = word
    if current:
        lines.append(current)
    return lines


def draw_wrapped(
    c: canvas.Canvas,
    text: str,
    rect: dict[str, float],
    font: str = "Helvetica",
    size: float = 10,
    leading: float | None = None,
) -> None:
    leading = leading or size * 1.15
    lines = wrap_lines(text, font, size, rect["width"])
    y = rect["y"] + rect["height"] - size
    c.saveState()
    c.setFont(font, size)
    c.setFillColor(black)
    for line in lines:
        if y < rect["y"]:
            break
        c.drawString(rect["x"], y, line)
        y -= leading
    c.restoreState()


def color_from_hex(value: str) -> Color:
    text = value.lstrip("#")
    if len(text) != 6:
        return Color(28 / 255.0, 39 / 255.0, 66 / 255.0, 1)
    return Color(int(text[0:2], 16) / 255.0, int(text[2:4], 16) / 255.0, int(text[4:6], 16) / 255.0, 1)


def transform_logo_point(x: float, y: float, bounds: tuple[float, float, float, float], fitted: dict[str, float]) -> tuple[float, float]:
    min_x, min_y, _max_x, max_y = bounds
    scale = fitted["scale"]
    return fitted["x"] + (x - min_x) * scale, fitted["y"] + (max_y - y) * scale


def draw_vector_logo(c: canvas.Canvas, logo_asset: dict[str, Any], container: dict[str, float]) -> None:
    min_x, min_y, max_x, max_y = logo_asset["bounds"]
    width = max_x - min_x
    height = max_y - min_y
    scale = min(container["width"] / width, container["height"] / height)
    fitted = {
        "x": container["x"] + (container["width"] - width * scale) / 2.0,
        "y": container["y"] + (container["height"] - height * scale) / 2.0,
        "scale": scale,
    }
    c.saveState()
    for shape in logo_asset["shapes"]:
        path = c.beginPath()
        for command, values in shape["commands"]:
            if command == "M":
                path.moveTo(*transform_logo_point(values[0], values[1], logo_asset["bounds"], fitted))
            elif command == "L":
                path.lineTo(*transform_logo_point(values[0], values[1], logo_asset["bounds"], fitted))
            elif command == "C":
                p1 = transform_logo_point(values[0], values[1], logo_asset["bounds"], fitted)
                p2 = transform_logo_point(values[2], values[3], logo_asset["bounds"], fitted)
                p3 = transform_logo_point(values[4], values[5], logo_asset["bounds"], fitted)
                path.curveTo(*p1, *p2, *p3)
            elif command == "Z":
                path.close()
        c.setFillColor(color_from_hex(shape.get("fill") or "#1c2742"))
        c.drawPath(path, stroke=0, fill=1)
    c.restoreState()


def draw_logo(c: canvas.Canvas, logo_asset: dict[str, Any] | None, cover: bool = False) -> None:
    container = (
        {"x": 72, "y": PAGE_HEIGHT - 160, "width": PAGE_WIDTH - 144, "height": 80}
        if cover
        else {"x": (PAGE_WIDTH - 170) / 2, "y": PAGE_HEIGHT - 56, "width": 170, "height": 34}
    )
    if logo_asset and logo_asset.get("kind") == "vector":
        draw_vector_logo(c, logo_asset, container)
        return
    if logo_asset and logo_asset.get("kind") == "png" and pathlib.Path(logo_asset.get("path") or "").exists():
        logo_png = logo_asset["path"]
        with Image.open(logo_png) as image:
            fitted = aspect_fit_rect(image.size, container)
        c.drawImage(
            ImageReader(logo_png),
            fitted["x"],
            fitted["y"],
            fitted["width"],
            fitted["height"],
            preserveAspectRatio=False,
            mask="auto",
        )
        return
    c.saveState()
    c.setFillColor(Color(28 / 255.0, 39 / 255.0, 66 / 255.0, 1))
    if cover:
        c.setFont("Helvetica-Bold", 54)
        c.drawCentredString(PAGE_WIDTH / 2, PAGE_HEIGHT - 126, "SCOUT")
    else:
        c.setFont("Helvetica-Bold", 21)
        c.drawCentredString(PAGE_WIDTH / 2, PAGE_HEIGHT - 48, "SCOUT")
    c.restoreState()


def draw_footer(c: canvas.Canvas, page_number: int, address: str | None = None, extra: str | None = None) -> None:
    margin = 64.0
    if address is not None:
        disclaimer = BASE_FOOTER + (f" {extra}" if extra else "")
        draw_wrapped(c, disclaimer, {"x": margin, "y": 24, "width": PAGE_WIDTH - margin * 2, "height": 56}, size=8)
        draw_text(c, address, {"x": margin, "y": 10, "width": PAGE_WIDTH - margin * 2, "height": 12}, size=9)
    draw_text(c, f"Page {page_number}", {"x": 0, "y": 10, "width": PAGE_WIDTH - margin, "height": 12}, size=10, align="right")


def prepare_pdf_image(source: str | None, work_dir: pathlib.Path, key: str, warnings: list[str]) -> str | None:
    if not source:
        return None
    source_path = pathlib.Path(source)
    if not source_path.exists():
        warnings.append(f"prepared_media_missing_on_disk:{source}")
        return None
    output = work_dir / f"{key}.jpg"
    with Image.open(source_path) as image:
        image = image.convert("RGB")
        width, height = image.size
        long_edge = max(width, height)
        if long_edge > PDF_IMAGE_MAX_LONG_EDGE:
            scale = PDF_IMAGE_MAX_LONG_EDGE / float(long_edge)
            image = image.resize((round(width * scale), round(height * scale)), Image.Resampling.LANCZOS)
        image.save(output, "JPEG", quality=PDF_IMAGE_JPEG_QUALITY, optimize=False, progressive=False)
    return str(output)


def clip_rounded(c: canvas.Canvas, rect: dict[str, float], radius: float) -> None:
    path = c.beginPath()
    path.roundRect(rect["x"], rect["y"], rect["width"], rect["height"], radius)
    c.clipPath(path, stroke=0, fill=0)


def draw_image_slot(c: canvas.Canvas, image_path: str | None, rect: dict[str, float] | None, placeholder: str | None, state: str, border_color: tuple[float, float, float] | None, work_dir: pathlib.Path, key: str, warnings: list[str]) -> None:
    if image_path and rect:
        optimized = prepare_pdf_image(image_path, work_dir, key, warnings)
        if optimized:
            c.saveState()
            clip_rounded(c, rect, 12)
            c.drawImage(ImageReader(optimized), rect["x"], rect["y"], rect["width"], rect["height"], preserveAspectRatio=False, mask=None)
            c.restoreState()
            if border_color:
                c.saveState()
                c.setStrokeColor(color_tuple(border_color))
                c.setLineWidth(3)
                c.roundRect(rect["x"] - 0.5, rect["y"] - 0.5, rect["width"] + 1, rect["height"] + 1, 12.5, stroke=1, fill=0)
                c.restoreState()
            return
    box = rect or {"x": 72, "y": 250, "width": 468, "height": 350}
    c.saveState()
    c.setFillColor(white)
    c.roundRect(box["x"], box["y"], box["width"], box["height"], 12, stroke=0, fill=1)
    c.setStrokeColor(black)
    c.setLineWidth(3)
    c.roundRect(box["x"], box["y"], box["width"], box["height"], 12, stroke=1, fill=0)
    c.restoreState()
    placeholder_text = placeholder or "IMAGE UNAVAILABLE"
    if placeholder_text == "No previous session photo available":
        font = "Helvetica"
        size = 11.0
        leading = size * 1.2
        lines = wrap_lines(placeholder_text, font, size, max(1.0, box["width"] - 24.0))
        block_h = leading * len(lines)
        y = box["y"] + box["height"] / 2.0 + block_h / 2.0 - size
        c.saveState()
        c.setFont(font, size)
        c.setFillColor(Color(0.35, 0.35, 0.35, 1))
        for line in lines:
            c.drawCentredString(box["x"] + box["width"] / 2.0, y, line)
            y -= leading
        c.restoreState()
        return
    words = placeholder_text.replace("_", " ").replace("-", " ").upper().split()
    text = "\n".join(words)
    draw_multiline_center(c, text, box, "Helvetica-Bold", 14)


def draw_multiline_center(c: canvas.Canvas, text: str, rect: dict[str, float], font: str, size: float) -> None:
    lines = text.splitlines() or [text]
    leading = size * 1.2
    block_h = leading * len(lines)
    y = rect["y"] + rect["height"] / 2.0 + block_h / 2.0 - size
    c.saveState()
    c.setFont(font, size)
    c.setFillColor(black)
    for line in lines:
        c.drawCentredString(rect["x"] + rect["width"] / 2.0, y, line)
        y -= leading
    c.restoreState()


def draw_state_marker(c: canvas.Canvas, x: float, y: float, size: float, state: str) -> None:
    rgb = visual_state_rgb(state)
    color = (rgb[0] / 255.0, rgb[1] / 255.0, rgb[2] / 255.0)

    def transform(point: tuple[float, float]) -> tuple[float, float]:
        return x + (point[0] / 24.0) * size, y + ((24.0 - point[1]) / 24.0) * size

    c.saveState()
    c.setFillColor(color_tuple(color))
    path = c.beginPath()
    for command, values in FILLED_FLAG_PATH:
        if command == "M":
            path.moveTo(*transform((values[0], values[1])))
        elif command == "L":
            path.lineTo(*transform((values[0], values[1])))
        elif command == "Z":
            path.close()
    c.drawPath(path, stroke=0, fill=1)
    c.restoreState()


def draw_note(c: canvas.Canvas, text: str, rect: dict[str, float], state: str, align: str = "center", size: float = 10.0) -> None:
    c.saveState()
    c.setFont("Helvetica", size)
    font_size = size
    glyph_size = size * 0.96
    icon_min_x, icon_min_y, icon_max_x, icon_max_y = FILLED_FLAG_BOUNDS
    glyph_visible_width = glyph_size * ((icon_max_x - icon_min_x) / 24.0)
    glyph_visible_height = glyph_size * ((icon_max_y - icon_min_y) / 24.0)
    gap = 3.0
    total = text_width(text, "Helvetica", font_size) + glyph_visible_width + gap
    if align == "center":
        start_x = rect["x"] + max(0, (rect["width"] - total) / 2.0)
    else:
        start_x = rect["x"]
    y = rect["y"] + max(0, (rect["height"] - font_size) / 2.0)
    cap_center = y + font_size * 0.47
    icon_box_y = cap_center - glyph_visible_height / 2.0 - (icon_min_y / 24.0) * glyph_size
    icon_box_x = start_x - (icon_min_x / 24.0) * glyph_size
    draw_state_marker(c, icon_box_x, icon_box_y, glyph_size, state)
    c.setFillColor(black)
    c.drawString(start_x + glyph_visible_width + gap, y, text)
    c.restoreState()


def draw_priority_note(c: canvas.Canvas, priority: str, reason: str | None, rect: dict[str, float]) -> None:
    label = PRIORITY_LABELS[priority]
    reason_text = trim(reason) or "No reason provided"
    prefix = f"{label} (Priority) - "
    suffix = f" - {reason_text}"
    c.saveState()
    c.setFont("Helvetica", 10)
    font_size = 10.0
    glyph_size = 9.6
    icon_min_x, icon_min_y, icon_max_x, icon_max_y = FILLED_FLAG_BOUNDS
    glyph_visible_width = glyph_size * ((icon_max_x - icon_min_x) / 24.0)
    glyph_visible_height = glyph_size * ((icon_max_y - icon_min_y) / 24.0)
    gap = 3.0
    total = text_width(prefix + suffix, "Helvetica", font_size) + 11 + glyph_visible_width + gap
    start_x = rect["x"] + max(0, (rect["width"] - total) / 2.0)
    y = rect["y"] + max(0, (rect["height"] - font_size) / 2.0)
    c.setFillColor(color_tuple(PRIORITY_COLORS[priority]))
    c.circle(start_x + 4, y + 4, 3, stroke=0, fill=1)
    c.setFillColor(black)
    text_x = start_x + 11
    c.drawString(text_x, y, prefix)
    flag_x = text_x + text_width(prefix, "Helvetica", 10)
    cap_center = y + font_size * 0.47
    icon_box_y = cap_center - glyph_visible_height / 2.0 - (icon_min_y / 24.0) * glyph_size
    icon_box_x = flag_x - (icon_min_x / 24.0) * glyph_size
    draw_state_marker(c, icon_box_x, icon_box_y, glyph_size, "flagged")
    c.drawString(flag_x + glyph_visible_width + gap, y, suffix)
    c.restoreState()


def draw_metadata(c: canvas.Canvas, entry: dict[str, Any], rect: dict[str, float], priority: str | None = None) -> None:
    top_y = rect["y"] + rect["height"] - 14
    draw_text(c, entry.get("caption") or "", {"x": rect["x"], "y": top_y, "width": rect["width"], "height": 14}, "Helvetica-Bold", 11, align="center")
    if priority:
        draw_priority_note(c, priority, entry.get("flagged_reason"), {"x": rect["x"], "y": top_y - 14, "width": rect["width"], "height": 14})
        draw_text(c, entry.get("captured_at_display") or "Unknown", {"x": rect["x"], "y": top_y - 28, "width": rect["width"], "height": 14}, size=10, align="center")
        return
    state = entry.get("visual_state") or "none"
    if state != "none":
        reason = trim(entry.get("flagged_reason"))
        note = f"Resolved - {reason}" if state == "resolved" and reason else ("Resolved" if state == "resolved" else (reason or "Flagged"))
        draw_note(c, note, {"x": rect["x"], "y": top_y - 14, "width": rect["width"], "height": 14}, state)
        draw_text(c, entry.get("captured_at_display") or "Unknown", {"x": rect["x"], "y": top_y - 28, "width": rect["width"], "height": 14}, size=10, align="center")
    else:
        draw_text(c, entry.get("captured_at_display") or "Unknown", {"x": rect["x"], "y": top_y - 14, "width": rect["width"], "height": 14}, size=10, align="center")


def draw_cover(c: canvas.Canvas, plan: dict[str, Any], page: dict[str, Any], work_dir: pathlib.Path, warnings: list[str], logo_asset: dict[str, Any] | None) -> None:
    session = plan["session"]
    draw_logo(c, logo_asset, cover=True)
    image_container = {"x": 126, "y": PAGE_HEIGHT - 360, "width": PAGE_WIDTH - 252, "height": 182}
    cover_path = page.get("cover_media_path")
    fitted = None
    if cover_path and pathlib.Path(cover_path).exists():
        with Image.open(cover_path) as image:
            fitted = aspect_fit_rect(image.size, image_container)
    if fitted:
        draw_image_slot(c, cover_path, fitted, None, "none", None, work_dir, f"cover-{page['number']}", warnings)
    draw_text(c, page["title"], {"x": 72, "y": image_container["y"] - 54, "width": PAGE_WIDTH - 144, "height": 28}, "Helvetica-Bold", 20, align="center")
    offset = 96
    if page.get("subtitle"):
        draw_text(c, page["subtitle"], {"x": 72, "y": image_container["y"] - 80, "width": PAGE_WIDTH - 144, "height": 22}, "Helvetica", 14, align="center")
        offset = 120
    if page.get("supporting_line"):
        draw_text(c, page["supporting_line"], {"x": 72, "y": image_container["y"] - 104, "width": PAGE_WIDTH - 144, "height": 20}, size=11, fill=Color(0.25, 0.25, 0.25, 1), align="center")
        offset = 142
    details = [
        ("Property Name:", session.get("property_name") or "Unknown Property"),
        ("Property Address:", session.get("property_address") or "Unknown address"),
        ("Date of Service:", session.get("date_of_service") or "Unknown"),
        ("Time Window:", session.get("time_window") or "Unknown"),
        ("Report Reference ID:", session.get("report_reference_id") or ""),
        (None, ""),
        ("Prepared by:", ""),
        (None, "SCOUT - Visual Documentation Services"),
        (None, "Clear, time-stamped visual documentation of observable property conditions."),
        ("Report Date:", session.get("report_date") or ""),
    ]
    if session.get("weather_summary"):
        details.insert(4, ("Weather at service start:", session["weather_summary"]))
        details.insert(5, (None, "Weather data provided by Open-Meteo."))
    details.insert(min(5, len(details)), (None, "*Weather conditions may have affected visibility at the time of documentation"))
    y = image_container["y"] - offset
    for label, value in details:
        rect = {"x": 72, "y": y, "width": PAGE_WIDTH - 144, "height": 16}
        if label:
            draw_centered_labeled(c, label, value, rect)
        else:
            is_weather_note = value.startswith("*Weather")
            is_weather_credit = value == "Weather data provided by Open-Meteo."
            draw_text(c, value, rect, "Helvetica-Oblique" if is_weather_note or is_weather_credit else "Helvetica", 10 if is_weather_note or is_weather_credit else 11, align="center")
        if label == "Prepared by:":
            y -= 8
        y -= 12 if not value and not label else 18
    draw_footer(c, page["number"])


def draw_centered_labeled(c: canvas.Canvas, label: str, value: str, rect: dict[str, float]) -> None:
    label_font = "Helvetica-Bold"
    value_font = "Helvetica"
    total = text_width(label, label_font, 11) + (4 if value else 0) + text_width(value, value_font, 11)
    x = rect["x"] + max(0, (rect["width"] - total) / 2.0)
    y = rect["y"] + max(0, (rect["height"] - 11) / 2.0)
    c.saveState()
    c.setFillColor(black)
    c.setFont(label_font, 11)
    c.drawString(x, y, label)
    if value:
        c.setFont(value_font, 11)
        c.drawString(x + text_width(label, label_font, 11) + 4, y, value)
    c.restoreState()


def draw_scope(c: canvas.Canvas, plan: dict[str, Any], page: dict[str, Any], logo_png: str | None) -> None:
    draw_logo(c, logo_png)
    left = 64
    y = PAGE_HEIGHT - 126
    sections = [
        ("Documentation Scope", [
            "SCOUT documents observable property features as they appear at the time of service. Deliverables consist of time-stamped photographs and structured notes intended for reference and visual comparison over time.",
        ]),
        ("Inclusions", [
            "• Visual documentation of accessible exterior areas",
            "• Visual documentation of accessible interior common areas (if applicable)",
            "• Time-stamped photographs organized by area or elevation",
        ]),
        ("Exclusions", [
            "This report does not include:",
            "• Inspections, evaluations, or professional assessments",
            "• Engineering, architectural, or code compliance analysis",
            "• Testing, probing, monitoring, or measurements",
            "• Identification of concealed or latent conditions",
            "• Opinions regarding cause, severity, responsibility, or repair methods",
            "• Cost estimates, pricing, or scope recommendations",
        ]),
        ("Limitations", [
            "Documentation was limited by accessibility, visibility, weather conditions, lighting, and site conditions present at the time of service.",
            "Location-based descriptive notes are limited to factual identification of visually observable conditions only.",
            "This record reflects conditions observed only at the documented date and time. No ongoing monitoring or updates are implied.",
        ]),
        ("Use of record", [
            "This report is intended for documentation and recordkeeping purposes only. It is not suitable for design, construction planning, engineering evaluation, or regulatory compliance.",
            "Use of this report is limited to the client identified on Page 1 unless otherwise authorized in writing by SCOUT.",
        ]),
    ]
    for title, paragraphs in sections:
        draw_text(c, title, {"x": left, "y": y, "width": PAGE_WIDTH - 128, "height": 22}, "Helvetica-Bold", 19)
        y -= 22
        for paragraph in paragraphs:
            size = 10.5 if title == "Use of record" else 11
            lines = wrap_lines(paragraph, "Helvetica", size, PAGE_WIDTH - 128)
            c.saveState()
            c.setFont("Helvetica", size)
            c.setFillColor(black)
            for line in lines:
                c.drawString(left, y, line)
                y -= size * 1.25
            c.restoreState()
        y -= 14
    draw_footer(c, page["number"], plan["session"]["property_address"], page.get("footer_extra"))


def draw_index(c: canvas.Canvas, plan: dict[str, Any], page: dict[str, Any], logo_png: str | None) -> None:
    draw_logo(c, logo_png)
    draw_text(c, "Documentation Index", {"x": 64, "y": PAGE_HEIGHT - 100, "width": PAGE_WIDTH - 128, "height": 24}, "Helvetica-Bold", 24)
    if page.get("supporting_line"):
        draw_text(c, page["supporting_line"], {"x": 64, "y": PAGE_HEIGHT - 126, "width": PAGE_WIDTH - 128, "height": 16}, size=11, fill=Color(0.25, 0.25, 0.25, 1))
    if not page.get("lines"):
        draw_text(c, "No photos available for index.", {"x": 64, "y": PAGE_HEIGHT - 130, "width": PAGE_WIDTH - 128, "height": 16}, size=11)
    for line in page.get("lines") or []:
        rect = line["rect"]
        if line["kind"] == "sectionHeader":
            draw_text(c, line["text"], rect, "Helvetica-Bold", 11)
        elif line["kind"] == "photoItem":
            page_rect = {"x": rect["x"] + rect["width"] - 34, "y": rect["y"], "width": 34, "height": rect["height"]}
            text_rect = {"x": rect["x"], "y": rect["y"], "width": rect["width"] - 44, "height": rect["height"]}
            if line.get("is_flagged"):
                draw_note(c, line["text"], text_rect, line.get("visual_state") or "flagged", align="left", size=9)
            else:
                draw_text(c, line["text"], text_rect, size=9)
            if line.get("page_number") is not None:
                c.saveState()
                c.setStrokeColor(Color(0, 0, 0, 0.35))
                c.setLineWidth(0.6)
                c.setDash(1.5, 2.5)
                y = text_rect["y"] + text_rect["height"] / 2.0
                c.line(text_rect["x"] + text_rect["width"] + 2, y, page_rect["x"] - 4, y)
                c.restoreState()
                draw_text(c, str(line["page_number"]), page_rect, size=9, align="right")
        elif line["kind"] == "retiredNote":
            draw_text(c, line["text"], rect, "Helvetica-Bold", 9)
    extra = PRIORITY_FOOTER if page.get("supporting_line") else None
    draw_footer(c, page["number"], plan["session"]["property_address"], extra)


def draw_photo_page(c: canvas.Canvas, plan: dict[str, Any], page: dict[str, Any], work_dir: pathlib.Path, warnings: list[str], logo_png: str | None, priority: str | None = None) -> None:
    draw_logo(c, logo_png)
    if page["kind"] == "priority_photo":
        draw_text(c, f"{PRIORITY_LABELS[priority or 'medium']} Priority Observations", {"x": 18, "y": PAGE_HEIGHT - 34, "width": PAGE_WIDTH - 36, "height": 16}, "Helvetica-Bold", 11, fill=color_tuple(PRIORITY_COLORS[priority or "medium"]))
    for index, slot in enumerate(page.get("slots") or []):
        entry = slot["entry"]
        state = entry.get("visual_state") or "none"
        border = None
        if priority:
            border = PRIORITY_COLORS[priority]
        elif state == "flagged":
            border = FLAG_COLOR
        elif state == "resolved":
            border = RESOLVED_COLOR
        draw_image_slot(c, entry.get("media_path"), slot.get("image_rect"), slot.get("placeholder_reason"), state, border, work_dir, f"{page['number']}-{index}", warnings)
        draw_metadata(c, entry, slot["caption_rect"], priority=priority)
    extra = PRIORITY_FOOTER if priority else None
    draw_footer(c, page["number"], plan["session"]["property_address"], extra)


def draw_priority_section(c: canvas.Canvas, plan: dict[str, Any], page: dict[str, Any], logo_png: str | None) -> None:
    draw_logo(c, logo_png)
    priority = page["priority"]
    draw_multiline_center(
        c,
        f"{PRIORITY_LABELS[priority].upper()} PRIORITY\nOBSERVATIONS",
        {"x": 72, "y": PAGE_HEIGHT / 2 + 2, "width": PAGE_WIDTH - 144, "height": 76},
        "Helvetica-Bold",
        30,
    )
    draw_text(
        c,
        f"{page['entry_count']} flagged item{'' if page['entry_count'] == 1 else 's'}",
        {"x": 72, "y": PAGE_HEIGHT / 2 - 34, "width": PAGE_WIDTH - 144, "height": 20},
        size=12,
        fill=Color(0.25, 0.25, 0.25, 1),
        align="center",
    )
    draw_footer(c, page["number"], plan["session"]["property_address"], PRIORITY_FOOTER)


def draw_comparison_page(c: canvas.Canvas, plan: dict[str, Any], page: dict[str, Any], work_dir: pathlib.Path, warnings: list[str], logo_png: str | None) -> None:
    draw_logo(c, logo_png)
    for index, slot in enumerate(page["slots"]):
        entry = slot["entry"]
        state = entry.get("visual_state") or "none"
        border = FLAG_COLOR if state == "flagged" else RESOLVED_COLOR if state == "resolved" else None
        image_rect = slot.get("image_rect") or (slot.get("photo_available_rect") if slot.get("placeholder_reason") else None)
        draw_image_slot(c, entry.get("media_path"), image_rect, slot.get("placeholder_reason"), state, border, work_dir, f"{page['number']}-{index}", warnings)
        top_y = slot["caption_rect"]["y"] + slot["caption_rect"]["height"] - 14
        draw_text(c, entry.get("caption") or "", {"x": slot["caption_rect"]["x"], "y": top_y, "width": slot["caption_rect"]["width"], "height": 14}, "Helvetica-Bold", 11, align="center")
        if state != "none" and trim(entry.get("flagged_reason")):
            prefix = "Resolved - " if state == "resolved" else ""
            draw_note(c, prefix + trim(entry.get("flagged_reason")), {"x": slot["caption_rect"]["x"], "y": top_y - 14, "width": slot["caption_rect"]["width"], "height": 14}, state)
            session_y = top_y - 28
        else:
            session_y = top_y - 14
        label = "Current Session" if slot["role"] == "current" else "Previous Session"
        if not bool(entry.get("suppress_session_label")):
            draw_text(c, f"{label}: {entry.get('captured_at_display') or 'Unknown'}", {"x": slot["caption_rect"]["x"], "y": session_y, "width": slot["caption_rect"]["width"], "height": 14}, size=10, align="center")
    draw_footer(c, page["number"], plan["session"]["property_address"])


def render_pdf(plan: dict[str, Any], output_path: pathlib.Path) -> dict[str, Any]:
    warnings = list(plan.get("warnings") or [])
    work_dir = output_path.parent / "_pdf_image_cache" / output_path.stem
    work_dir.mkdir(parents=True, exist_ok=True)
    logo_asset = resolve_logo_asset(plan, work_dir, warnings)
    c = canvas.Canvas(str(output_path), pagesize=PAGE_SIZE, pageCompression=1, invariant=1)
    c.setTitle(output_path.stem)
    c.setAuthor("ScoutCapture Phase 2C Shadow Renderer")
    for page in plan["pages"]:
        c.setFillColor(white)
        c.rect(0, 0, PAGE_WIDTH, PAGE_HEIGHT, stroke=0, fill=1)
        kind = page["kind"]
        if kind == "cover":
            draw_cover(c, plan, page, work_dir, warnings, logo_asset)
        elif kind == "scope":
            draw_scope(c, plan, page, logo_asset)
        elif kind == "index":
            draw_index(c, plan, page, logo_asset)
        elif kind == "photo":
            draw_photo_page(c, plan, page, work_dir, warnings, logo_asset)
        elif kind == "priority_section":
            draw_priority_section(c, plan, page, logo_asset)
        elif kind == "priority_photo":
            draw_photo_page(c, plan, page, work_dir, warnings, logo_asset, priority=page["priority"])
        elif kind == "comparison_photo":
            draw_comparison_page(c, plan, page, work_dir, warnings, logo_asset)
        else:
            raise Phase2BError(f"Unsupported page kind: {kind}")
        c.showPage()
    c.save()
    return {"warnings": sorted(set(warnings))}


def pdf_validation(pdf_path: pathlib.Path) -> dict[str, Any]:
    reader = PdfReader(str(pdf_path))
    dims = []
    for page in reader.pages:
        box = page.mediabox
        dims.append({"width": float(box.width), "height": float(box.height)})
    return {
        "pdf_sha256": sha256_file(pdf_path),
        "pdf_byte_size": pdf_path.stat().st_size,
        "page_count": len(reader.pages),
        "page_dimensions": dims,
        "structurally_valid": True,
    }


def validate_dimensions(dims: list[dict[str, float]]) -> list[str]:
    failures = []
    for index, dim in enumerate(dims, start=1):
        if abs(dim["width"] - PAGE_WIDTH) > 0.01 or abs(dim["height"] - PAGE_HEIGHT) > 0.01:
            failures.append(f"page_{index}_dimension_mismatch:{dim['width']}x{dim['height']}")
    return failures


def render_previews(pdf_path: pathlib.Path, output_dir: pathlib.Path) -> dict[str, Any]:
    preview_dir = output_dir / "previews" / pdf_path.stem
    preview_dir.mkdir(parents=True, exist_ok=True)
    pdftoppm = pathlib.Path("/Users/brian/.cache/codex-runtimes/codex-primary-runtime/dependencies/bin/override/pdftoppm")
    if not pdftoppm.exists():
        found = shutil.which("pdftoppm")
        if not found:
            return {"preview_dir": str(preview_dir), "contact_sheet": None, "warning": "pdftoppm_not_available"}
        pdftoppm = pathlib.Path(found)
    prefix = preview_dir / "page"
    env = dict(os.environ)
    env.setdefault("XDG_CACHE_HOME", "/private/tmp/scoutcapture-font-cache")
    pathlib.Path(env["XDG_CACHE_HOME"]).mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [str(pdftoppm), "-png", "-r", "72", str(pdf_path), str(prefix)],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        env=env,
    )
    images = sorted(preview_dir.glob("page-*.png"))
    contact = output_dir / "contact_sheets" / f"{pdf_path.stem}.jpg"
    contact.parent.mkdir(parents=True, exist_ok=True)
    make_contact_sheet(images, contact)
    return {"preview_dir": str(preview_dir), "contact_sheet": str(contact), "page_preview_count": len(images)}


def make_contact_sheet(images: list[pathlib.Path], output_path: pathlib.Path, columns: int = 4) -> None:
    if not images:
        return
    thumbs = []
    for path in images:
        with Image.open(path) as image:
            image = image.convert("RGB")
            image.thumbnail((180, 233))
            canvas_img = Image.new("RGB", (180, 233), "white")
            canvas_img.paste(image, ((180 - image.width) // 2, (233 - image.height) // 2))
            thumbs.append((path.name, canvas_img))
    rows = math.ceil(len(thumbs) / columns)
    label_h = 18
    sheet = Image.new("RGB", (columns * 180, rows * (233 + label_h)), "white")
    draw = ImageDraw.Draw(sheet)
    try:
        font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf", 10)
    except Exception:
        font = ImageFont.load_default()
    for i, (name, thumb) in enumerate(thumbs):
        x = (i % columns) * 180
        y = (i // columns) * (233 + label_h)
        sheet.paste(thumb, (x, y))
        draw.text((x + 4, y + 234), name, fill=(0, 0, 0), font=font)
    sheet.save(output_path, "JPEG", quality=90)


def profile_stamped_oracles(paths: list[str], output_dir: pathlib.Path, pretty: bool) -> dict[str, Any]:
    profiles = []
    for raw in paths:
        path = pathlib.Path(raw)
        if not path.exists():
            profiles.append({"path": str(path), "exists": False})
            continue
        with Image.open(path) as image:
            width, height = image.size
            sample = image.convert("RGB")
            y0 = int(height * 0.80)
            dark_pixels = []
            for y in range(y0, height):
                for x in range(0, width, max(1, width // 300)):
                    r, g, b = sample.getpixel((x, y))
                    if r < 80 and g < 80 and b < 80:
                        dark_pixels.append((x, y))
            bbox = None
            if dark_pixels:
                xs = [p[0] for p in dark_pixels]
                ys = [p[1] for p in dark_pixels]
                bbox = {"x_min": min(xs), "y_min": min(ys), "x_max": max(xs), "y_max": max(ys)}
            profiles.append(
                {
                    "path": str(path),
                    "exists": True,
                    "filename": path.name,
                    "sha256": sha256_file(path),
                    "width": width,
                    "height": height,
                    "format": image.format,
                    "estimated_dark_stamp_region": bbox,
                    "observations": [
                        "stamp is bottom-right translucent rounded black pill",
                        "text is uppercase with vertical separators and date",
                        "flagged sample uses red flag glyph before text",
                    ],
                }
            )
    result = {"schema_version": SCHEMA_VERSION, "stamped_oracle_profiles": profiles}
    write_json(output_dir / "stamped_image_oracle_comparison.json", result, pretty)
    return result


def render_historical_oracles(paths: list[str], output_dir: pathlib.Path) -> list[dict[str, Any]]:
    results = []
    for raw in paths:
        path = pathlib.Path(raw)
        if not path.exists():
            results.append({"path": str(path), "exists": False})
            continue
        preview = render_previews(path, output_dir / "historical_oracle")
        info = pdf_validation(path)
        results.append({"path": str(path), "exists": True, **info, **preview})
    return results


def build_plan(
    report_type: str,
    validation: dict[str, Any],
    lookup: MediaLookup,
    report_date: str,
    logo: dict[str, Any],
    weather: dict[str, Any],
    validation_lookup_dir: pathlib.Path | None,
) -> dict[str, Any]:
    if report_type == "property":
        return build_property_plan(validation, lookup, report_date, logo, weather)
    if report_type == "priority":
        return build_priority_plan(validation, lookup, report_date, logo, weather)
    if report_type == "comparison":
        return build_comparison_plan(validation, lookup, report_date, logo, weather, validation_lookup_dir)
    raise Phase2BError(f"Unknown report type {report_type}")


def main() -> int:
    args = parse_args()
    validation_path = pathlib.Path(args.validation_json)
    media_path = pathlib.Path(args.prepared_media_json)
    output_dir = pathlib.Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    validation = read_json(validation_path)
    prepared = read_json(media_path)
    lookup = media_lookup(prepared)
    logo = logo_info(args.logo_pdf, args.logo_svg)
    weather_warnings: list[str] = []
    weather_cache_path = pathlib.Path(args.weather_cache) if args.weather_cache else output_dir / "weather_cache.json"
    weather = resolve_weather_summary(validation, weather_cache_path, args.allow_weather_fetch, weather_warnings, args.pretty)
    weather["warnings"] = list(weather_warnings)
    report_date = args.report_date or dt.datetime.now(DISPLAY_TZ).strftime("%m/%d/%Y")
    reports = ["property", "priority", "comparison"] if args.report == "all" else [args.report]
    summary: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "phase": "ScoutCapture Phase 2C Visual Parity Renderer",
        "production_writes_made": False,
        "validation_json": str(validation_path),
        "prepared_media_json": str(media_path),
        "output_dir": str(output_dir),
        "generator_version": GENERATOR_VERSION,
        "logo": logo,
        "weather": weather,
        "weather_cache_path": str(weather_cache_path),
        "reports": [],
        "skipped_reports": [],
        "historical_oracles": [],
        "stamped_oracles": [],
        "warnings": weather_warnings,
    }
    for report_type in reports:
        report_dir = output_dir / report_type
        report_dir.mkdir(parents=True, exist_ok=True)
        try:
            plan = build_plan(report_type, validation, lookup, report_date, logo, weather, validation_path.parent)
        except Phase2BError as error:
            if args.report == "all" and is_not_applicable_error(error):
                skip = {"report_type": report_type, "reason": str(error)}
                summary["skipped_reports"].append(skip)
                print(f"Skipping {report_type} report: {error}", file=sys.stderr)
                continue
            raise
        plan_path = report_dir / f"report_plan_{report_type}.json"
        write_json(plan_path, plan, args.pretty)
        pdf_path = report_dir / plan["output_filename"]
        render_info = render_pdf(plan, pdf_path)
        validation_info = pdf_validation(pdf_path)
        failures = validate_dimensions(validation_info["page_dimensions"])
        manifest = {
            "schema_version": SCHEMA_VERSION,
            "phase": "ScoutCapture Phase 2C PDF Validation",
            "session_id": plan.get("session_id"),
            "source_snapshot_id": plan.get("source_snapshot_id"),
            "report_type": report_type,
            "output_filename": plan["output_filename"],
            "generator_version": GENERATOR_VERSION,
            "report_plan_path": str(plan_path),
            "report_plan_sha256": plan["report_plan_sha256"],
            "prepared_media_hashes": plan["prepared_media_hashes"],
            "pdf_path": str(pdf_path),
            **validation_info,
            "warnings": sorted(set(plan.get("warnings", []) + render_info.get("warnings", []))),
            "validation_failures": failures,
        }
        validation_path_out = report_dir / f"validation_{report_type}.json"
        write_json(validation_path_out, manifest, args.pretty)
        preview = render_previews(pdf_path, report_dir)
        summary["reports"].append(
            {
                "report_type": report_type,
                "plan_path": str(plan_path),
                "validation_path": str(validation_path_out),
                "pdf_path": str(pdf_path),
                "report_plan_sha256": plan["report_plan_sha256"],
                "pdf_sha256": validation_info["pdf_sha256"],
                "page_count": validation_info["page_count"],
                **preview,
                "warnings": manifest["warnings"],
                "validation_failures": failures,
            }
        )
    if args.historical_oracle:
        summary["historical_oracles"] = render_historical_oracles(args.historical_oracle, output_dir)
    if args.stamped_oracle:
        summary["stamped_oracles"] = profile_stamped_oracles(args.stamped_oracle, output_dir, args.pretty).get("stamped_oracle_profiles", [])
    write_json(output_dir / "phase2c_summary.json", summary, args.pretty)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"Phase 2C renderer failed: {error}", file=sys.stderr)
        raise
