#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import pathlib
import sys
import types
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
RENDERER_PATH = ROOT / "web-contract" / "report-renderer" / "report_renderer_phase2b.py"


def install_optional_dependency_stubs() -> None:
    if importlib.util.find_spec("PIL") is None:
        pil = types.ModuleType("PIL")
        pil.Image = types.SimpleNamespace()
        pil.ImageDraw = types.SimpleNamespace()
        pil.ImageFont = types.SimpleNamespace()
        sys.modules["PIL"] = pil
        sys.modules["PIL.Image"] = pil.Image
        sys.modules["PIL.ImageDraw"] = pil.ImageDraw
        sys.modules["PIL.ImageFont"] = pil.ImageFont
    if importlib.util.find_spec("pypdf") is None:
        pypdf = types.ModuleType("pypdf")
        pypdf.PdfReader = object
        sys.modules["pypdf"] = pypdf
    if importlib.util.find_spec("reportlab") is None:
        reportlab = types.ModuleType("reportlab")
        lib = types.ModuleType("reportlab.lib")
        colors = types.ModuleType("reportlab.lib.colors")
        utils = types.ModuleType("reportlab.lib.utils")
        pdfbase = types.ModuleType("reportlab.pdfbase")
        pdfmetrics = types.ModuleType("reportlab.pdfbase.pdfmetrics")
        pdfgen = types.ModuleType("reportlab.pdfgen")
        canvas = types.ModuleType("reportlab.pdfgen.canvas")

        class Color:
            def __init__(self, *args: object) -> None:
                self.args = args

        colors.Color = Color
        colors.black = Color(0, 0, 0, 1)
        colors.white = Color(1, 1, 1, 1)
        utils.ImageReader = object
        canvas.Canvas = object
        sys.modules.update(
            {
                "reportlab": reportlab,
                "reportlab.lib": lib,
                "reportlab.lib.colors": colors,
                "reportlab.lib.utils": utils,
                "reportlab.pdfbase": pdfbase,
                "reportlab.pdfbase.pdfmetrics": pdfmetrics,
                "reportlab.pdfgen": pdfgen,
                "reportlab.pdfgen.canvas": canvas,
            }
        )


install_optional_dependency_stubs()
SPEC = importlib.util.spec_from_file_location("report_renderer_phase2b", RENDERER_PATH)
renderer = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules["report_renderer_phase2b"] = renderer
SPEC.loader.exec_module(renderer)


SESSION_ID = "11111111-1111-4111-8111-111111111111"
CURRENT_SHOT_ID = "22222222-2222-4222-8222-222222222222"
PREVIOUS_SHOT_ID = "33333333-3333-4333-8333-333333333333"


def media_lookup() -> object:
    return renderer.MediaLookup(by_role_shot={}, all_hashes=[], warnings=[])


def validation() -> dict:
    current = {
        "session_id": SESSION_ID,
        "shot_id": CURRENT_SHOT_ID,
        "building": "Building 1",
        "elevation": "North",
        "detail_type": "Door",
        "angle_index": 1,
        "shot_key": "A1",
        "captured_at_utc": "2026-09-22T14:30:00Z",
        "original_filename": "resolved-current.jpg",
        "is_flagged": True,
        "is_resolved_in_session": False,
        "issueStatus": "pending_review",
        "captureKind": "resolvedCapture",
        "flagged_reason": "Paint touched up",
        "normalized_priority": "high",
    }
    return {
        "schema_version": "phase1-report-input-1",
        "source_snapshot_id": "44444444-4444-4444-8444-444444444444",
        "inputs": {
            "session": {
                "session_id": SESSION_ID,
                "property_name": "Resolved Parity",
                "property_address": "123 Green Check Way",
                "started_at_utc": "2026-09-22T14:00:00Z",
                "ended_at_utc": "2026-09-22T15:00:00Z",
            },
            "ordered_shots": [current],
            "property_report_entries": [
                {
                    "kind": "photo",
                    "shot_id": CURRENT_SHOT_ID,
                }
            ],
        },
        "comparisons": {
            "items": [
                {
                    "current_shot_id": CURRENT_SHOT_ID,
                    "previous_shot_id": PREVIOUS_SHOT_ID,
                    "previous_session_id": "55555555-5555-4555-8555-555555555555",
                    "previous_session_date_utc": "2026-08-22T14:00:00Z",
                    "previous_captured_at_utc": "2026-08-22T14:30:00Z",
                }
            ]
        },
    }


class ReportRendererResolvedParityTests(unittest.TestCase):
    def test_pending_review_item_gets_resolved_visual_state(self) -> None:
        self.assertEqual(
            "resolved",
            renderer.visual_state(
                {
                    "issueStatus": "pending_review",
                    "is_resolved_in_session": False,
                    "captureKind": "followUpCapture",
                    "isFlagged": True,
                }
            ),
        )
        self.assertEqual(
            "resolved",
            renderer.visual_state(
                {
                    "captureKind": "resolvedCapture",
                    "isResolvedInSession": "false",
                    "isFlagged": True,
                }
            ),
        )

    def test_property_priority_and_comparison_plans_keep_resolved_current_photo(self) -> None:
        payload = validation()
        lookup = media_lookup()
        logo = {}
        weather = {}

        property_plan = renderer.build_property_plan(payload, lookup, "09/22/2026", logo, weather)
        property_slots = [
            slot
            for page in property_plan["pages"]
            if page.get("kind") == "photo"
            for slot in page.get("slots", [])
        ]
        self.assertEqual("resolved", property_slots[0]["entry"]["visual_state"])

        priority_plan = renderer.build_priority_plan(payload, lookup, "09/22/2026", logo, weather)
        priority_slots = [
            slot
            for page in priority_plan["pages"]
            if page.get("kind") == "priority_photo"
            for slot in page.get("slots", [])
        ]
        self.assertEqual("resolved", priority_slots[0]["entry"]["visual_state"])

        comparison_plan = renderer.build_comparison_plan(payload, lookup, "09/22/2026", logo, weather)
        comparison_page = next(page for page in comparison_plan["pages"] if page.get("kind") == "comparison_photo")
        slots_by_role = {slot["role"]: slot for slot in comparison_page["slots"]}
        self.assertEqual("resolved", slots_by_role["current"]["entry"]["visual_state"])
        self.assertEqual("flagged", slots_by_role["previous"]["entry"]["visual_state"])

    def test_photo_page_draw_recomputes_resolved_border_from_pending_review(self) -> None:
        calls = []
        metadata_states = []
        original_draw_image_slot = renderer.draw_image_slot
        original_draw_metadata = renderer.draw_metadata
        original_draw_logo = renderer.draw_logo
        original_draw_footer = renderer.draw_footer
        original_draw_text = renderer.draw_text
        try:
            renderer.draw_image_slot = lambda _c, _image_path, _rect, _placeholder, state, border, _work_dir, _key, _warnings: calls.append(
                {"state": state, "border": border}
            )
            renderer.draw_metadata = lambda _c, entry, _rect, priority=None: metadata_states.append(
                {"state": entry.get("visual_state"), "priority": priority}
            )
            renderer.draw_logo = lambda *_args, **_kwargs: None
            renderer.draw_footer = lambda *_args, **_kwargs: None
            renderer.draw_text = lambda *_args, **_kwargs: None
            page = {
                "number": 9,
                "kind": "priority_photo",
                "slots": [
                    {
                        "entry": {
                            "caption": "Building 1 | North | Door | A1",
                            "visual_state": "flagged",
                            "issueStatus": "pending_review",
                            "captureKind": "resolvedCapture",
                            "isFlagged": True,
                            "flagged_reason": "Paint touched up",
                        },
                        "image_rect": {"x": 1, "y": 2, "width": 3, "height": 4},
                        "caption_rect": {"x": 1, "y": 2, "width": 3, "height": 4},
                    }
                ],
            }

            renderer.draw_photo_page(
                None,
                {"session": {"property_address": "123 Green Check Way"}},
                page,
                pathlib.Path("."),
                [],
                None,
                priority="high",
            )
        finally:
            renderer.draw_image_slot = original_draw_image_slot
            renderer.draw_metadata = original_draw_metadata
            renderer.draw_logo = original_draw_logo
            renderer.draw_footer = original_draw_footer
            renderer.draw_text = original_draw_text

        self.assertEqual([{"state": "resolved", "border": renderer.RESOLVED_COLOR}], calls)
        self.assertEqual([{"state": "resolved", "priority": "high"}], metadata_states)

    def test_comparison_draw_keeps_previous_red_and_current_resolved_green(self) -> None:
        image_calls = []
        notes = []
        original_draw_image_slot = renderer.draw_image_slot
        original_draw_note = renderer.draw_note
        original_draw_logo = renderer.draw_logo
        original_draw_footer = renderer.draw_footer
        original_draw_text = renderer.draw_text
        try:
            renderer.draw_image_slot = lambda _c, _image_path, _rect, _placeholder, state, border, _work_dir, _key, _warnings: image_calls.append(
                {"state": state, "border": border}
            )
            renderer.draw_note = lambda _c, text, _rect, state, **_kwargs: notes.append(
                {"text": text, "state": state}
            )
            renderer.draw_logo = lambda *_args, **_kwargs: None
            renderer.draw_footer = lambda *_args, **_kwargs: None
            renderer.draw_text = lambda *_args, **_kwargs: None
            base_slot = {
                "image_rect": {"x": 1, "y": 2, "width": 3, "height": 4},
                "caption_rect": {"x": 1, "y": 2, "width": 120, "height": 40},
            }
            page = {
                "number": 10,
                "kind": "comparison_photo",
                "slots": [
                    {
                        **base_slot,
                        "role": "current",
                        "entry": {
                            "caption": "Current",
                            "visual_state": "flagged",
                            "issueStatus": "pending_review",
                            "captureKind": "resolvedCapture",
                            "isFlagged": True,
                            "flagged_reason": "Paint touched up",
                        },
                    },
                    {
                        **base_slot,
                        "role": "previous",
                        "entry": {
                            "caption": "Previous",
                            "visual_state": "flagged",
                            "flagged_reason": "Paint touched up",
                        },
                    },
                ],
            }

            renderer.draw_comparison_page(
                None,
                {"session": {"property_address": "123 Green Check Way"}},
                page,
                pathlib.Path("."),
                [],
                None,
            )
        finally:
            renderer.draw_image_slot = original_draw_image_slot
            renderer.draw_note = original_draw_note
            renderer.draw_logo = original_draw_logo
            renderer.draw_footer = original_draw_footer
            renderer.draw_text = original_draw_text

        self.assertEqual(
            [
                {"state": "resolved", "border": renderer.RESOLVED_COLOR},
                {"state": "flagged", "border": renderer.FLAG_COLOR},
            ],
            image_calls,
        )
        self.assertEqual(
            [
                {"text": "Resolved - Paint touched up", "state": "resolved"},
                {"text": "Paint touched up", "state": "flagged"},
            ],
            notes,
        )


if __name__ == "__main__":
    unittest.main()
