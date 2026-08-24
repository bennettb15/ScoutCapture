"""Shared Scout report visual constants for shadow PDF/media tooling."""

from __future__ import annotations

FLAGGED_RGB = (211, 47, 47)
RESOLVED_RGB = (38, 173, 86)

# Google Material Icons "flag" filled icon.
# Source: https://fonts.google.com/icons?selected=Material+Icons:flag
# License: Apache License Version 2.0
FILLED_FLAG_SOURCE = "Google Material Icons filled flag"
FILLED_FLAG_SOURCE_URL = "https://fonts.google.com/icons?selected=Material+Icons:flag"
FILLED_FLAG_LICENSE = "Apache-2.0"
FILLED_FLAG_VIEWBOX = (0.0, 0.0, 24.0, 24.0)
FILLED_FLAG_BOUNDS = (5.0, 4.0, 20.0, 21.0)
FILLED_FLAG_PATH = (
    ("M", (14.4, 6.0)),
    ("L", (14.0, 4.0)),
    ("L", (5.0, 4.0)),
    ("L", (5.0, 21.0)),
    ("L", (7.0, 21.0)),
    ("L", (7.0, 14.0)),
    ("L", (12.6, 14.0)),
    ("L", (13.0, 16.0)),
    ("L", (20.0, 16.0)),
    ("L", (20.0, 6.0)),
    ("Z", ()),
)


def visual_state_rgb(state: str) -> tuple[int, int, int]:
    return RESOLVED_RGB if state == "resolved" else FLAGGED_RGB


def filled_flag_polygon() -> tuple[tuple[float, float], ...]:
    points: list[tuple[float, float]] = []
    for command, values in FILLED_FLAG_PATH:
        if command == "M":
            points.append((values[0], values[1]))
        elif command == "L":
            points.append((values[0], values[1]))
    return tuple(points)


def filled_flag_metadata() -> dict[str, object]:
    return {
        "source": FILLED_FLAG_SOURCE,
        "source_url": FILLED_FLAG_SOURCE_URL,
        "license": FILLED_FLAG_LICENSE,
        "viewbox": FILLED_FLAG_VIEWBOX,
        "bounds": FILLED_FLAG_BOUNDS,
        "treatment": "solid filled glyph",
    }
