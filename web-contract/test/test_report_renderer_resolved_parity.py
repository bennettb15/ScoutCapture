#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import json
import pathlib
import sys
import types
import unittest
from unittest.mock import MagicMock, patch


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
        pdfmetrics.stringWidth = lambda value, _font, size: len(value) * size * 0.5
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
    def test_all_three_indexes_use_the_field_resolution_outcome(self) -> None:
        for status, label in (("pending_review", "Resolved in field · Pending Review"), ("resolved", "Resolved")):
            payload = validation()
            payload["inputs"]["ordered_shots"][0]["issueStatus"] = status
            for builder in (renderer.build_property_plan, renderer.build_priority_plan, renderer.build_comparison_plan):
                with self.subTest(report=builder.__name__, status=status):
                    plan = builder(payload, media_lookup(), "09/22/2026", {}, {})
                    lines = [line for page in plan["pages"] if page["kind"] == "index" for line in page["lines"]
                             if line["kind"] == "photoItem"]
                    self.assertEqual(1, len(lines))
                    self.assertTrue(lines[0]["text"].endswith(f" | {label}"), lines[0]["text"])
                    self.assertEqual(status, lines[0]["visual_state"])
                    self.assertTrue(" ".join(lines[0]["display_lines"]).endswith(label))

    def test_approval_overrides_a_stale_pending_snapshot(self) -> None:
        entry = {"issue_status": "pending_review", "reviewed_resolution_status": "resolved"}
        self.assertEqual("resolved", renderer.visual_state(entry))
        self.assertEqual("Resolved", renderer.resolution_label(entry))

    def test_comparison_index_wraps_and_reserves_the_page_number_column(self) -> None:
        payload = validation()
        shot = payload["inputs"]["ordered_shots"][0]
        shot["detail_type"] = "Exterior wall trim beside the rear covered pedestrian entrance " * 3
        plan = renderer.build_comparison_plan(payload, media_lookup(), "09/22/2026", {}, {})
        page = plan["pages"][1]
        row = next(line for line in page["lines"] if line["kind"] == "photoItem")
        self.assertGreater(len(row["display_lines"]), 1)
        self.assertTrue(" ".join(row["display_lines"]).endswith("Resolved in field · Pending Review"))
        self.assertEqual("comparison_photo", plan["pages"][row["page_number"] - 1]["kind"])

        canvas = MagicMock()
        with patch.object(renderer, "draw_logo"), patch.object(renderer, "draw_footer"):
            renderer.draw_index(canvas, plan, page, None)

        number_x, number_y, number_text = canvas.drawRightString.call_args.args
        self.assertEqual(str(row["page_number"]), number_text)
        self.assertEqual(row["rect"]["x"] + row["rect"]["width"], number_x)
        text_right = number_x - renderer.INDEX_PAGE_NUMBER_WIDTH - renderer.INDEX_COLUMN_GAP
        for index, text in enumerate(row["display_lines"]):
            x, y, _ = next(call.args for call in canvas.drawString.call_args_list if call.args[-1] == text)
            self.assertAlmostEqual(number_y - index * renderer.INDEX_CONTINUATION_HEIGHT, y)
            self.assertLessEqual(x + renderer.text_width(text, "Helvetica", renderer.INDEX_FONT_SIZE), text_right)

    def test_index_uses_wrapped_row_height_when_paginating(self) -> None:
        text = "An intentionally wide exterior detail " * 11 + "| Resolved in field · Pending Review"
        rows = [
            {"kind": "photoItem", "text": text, "page_number": index + 8, "is_flagged": True, "visual_state": "pending_review"}
            for index in range(36)
        ]
        pages = renderer.index_page_plans(rows, line_offset=28)
        self.assertGreater(len(pages), 1)
        self.assertEqual([row["page_number"] for row in rows], [row["page_number"] for page in pages for row in page])
        for page in pages:
            self.assertTrue(all(row["rect"]["y"] >= 96 for row in page))
            for upper, lower in zip(page, page[1:]):
                self.assertGreater(upper["rect"]["y"], lower["rect"]["y"] + lower["rect"]["height"])

    def test_pending_marker_uses_a_stroked_lens_and_handle(self) -> None:
        canvas = MagicMock()
        renderer.draw_state_marker(canvas, 0, 0, 12, "pending_review")
        canvas.circle.assert_called_once()
        self.assertEqual({"stroke": 1, "fill": 0}, canvas.circle.call_args.kwargs)
        canvas.line.assert_called_once()
        canvas.drawPath.assert_not_called()

    def test_reviewed_rejection_overrides_the_historical_resolution_capture(self) -> None:
        payload = validation()
        shot = payload["inputs"]["ordered_shots"][0]
        shot.update(reviewed_resolution_status="active", issue_status="active", is_resolved_in_session=False)
        for builder in (renderer.build_property_plan, renderer.build_priority_plan, renderer.build_comparison_plan):
            with self.subTest(report=builder.__name__):
                plan = builder(payload, media_lookup(), "09/22/2026", {}, {})
                entries = [slot["entry"] for page in plan["pages"] for slot in page.get("slots", [])
                           if slot["entry"]["shot_id"] == CURRENT_SHOT_ID]
                self.assertTrue(entries)
                self.assertTrue(all(renderer.visual_state(entry) == "flagged" for entry in entries))
                self.assertTrue(all(renderer.resolution_label(entry) is None for entry in entries))

    def test_customer_report_plans_omit_scope_and_keep_index_page_numbers(self) -> None:
        payload = validation()
        payload["inputs"]["session"]["org_name"] = "Example Property Group"
        for builder in (
            renderer.build_property_plan,
            renderer.build_priority_plan,
            renderer.build_comparison_plan,
        ):
            with self.subTest(report=builder.__name__):
                plan = builder(payload, media_lookup(), "09/22/2026", {}, {})
                pages = plan["pages"]
                self.assertEqual("Example Property Group", plan["session"]["org_name"])
                self.assertEqual("cover", pages[0]["kind"])
                self.assertEqual("index", pages[1]["kind"])
                self.assertNotIn("scope", [page["kind"] for page in pages])
                self.assertEqual(list(range(1, len(pages) + 1)), [page["number"] for page in pages])
                photo_numbers = {
                    page["number"]
                    for page in pages
                    if page["kind"] in ("photo", "priority_photo", "comparison_photo")
                }
                index_references = {
                    line["page_number"]
                    for page in pages
                    if page["kind"] == "index"
                    for line in page["lines"]
                    if line["kind"] == "photoItem"
                }
                self.assertTrue(index_references)
                self.assertTrue(index_references <= photo_numbers)

    def test_overview_cover_uses_full_photo_collection_for_all_report_types(self) -> None:
        payload = validation()
        flagged = payload["inputs"]["ordered_shots"][0]
        # The overview was taken after the first detail photo and is deliberately
        # absent from the current punchlist-only collection.
        overview = {**flagged, "shot_id": "overview-first", "detail_type": "Overview",
                    "is_flagged": False, "is_resolved_in_session": False,
                    "issueStatus": "", "captureKind": "captured", "captured_at_utc": "2026-09-22T14:45:00Z"}
        later = {**overview, "shot_id": "overview-later", "captured_at_utc": "2026-09-22T14:50:00Z"}
        payload["inputs"]["ordered_shots"] = [flagged, later, overview]
        payload["inputs"]["punchlist_shots"] = [flagged]
        lookup = renderer.media_lookup({"items": [{"role": "current", "shot_id": item["shot_id"],
            "temporary_prepared_path": f"/{item['shot_id']}.jpg"} for item in [flagged, overview, later]]})
        for builder in (renderer.build_property_plan, renderer.build_priority_plan, renderer.build_comparison_plan):
            with self.subTest(report=builder.__name__):
                plan = builder(payload, lookup, "09/22/2026", {}, {})
                self.assertEqual("/overview-first.jpg", plan["pages"][0]["cover_media_path"])
                self.assertEqual("overview-first", plan["pages"][0]["cover_shot_id"])
        # Cover selection must not add an unflagged overview to the issue pages.
        priority = renderer.build_priority_plan(payload, lookup, "09/22/2026", {}, {})
        body = [slot["entry"]["shot_id"] for page in priority["pages"] if page["kind"] == "priority_photo" for slot in page["slots"]]
        self.assertEqual([CURRENT_SHOT_ID], body)
        comparison = renderer.build_comparison_plan(payload, lookup, "09/22/2026", {}, {})
        current = [slot["entry"]["shot_id"] for page in comparison["pages"] if page["kind"] == "comparison_photo" for slot in page["slots"] if slot["role"] == "current"]
        self.assertEqual([CURRENT_SHOT_ID], current)

    def test_punchlist_update_cover_also_uses_the_first_overview(self) -> None:
        payload = validation()
        detail = {**payload['inputs']['ordered_shots'][0], 'capture_kind':'follow_up_capture'}
        overview = {**detail, 'shot_id':'overview', 'detail_type':'Overview', 'capture_kind':'captured'}
        payload['inputs']['ordered_shots'] = [detail, overview]
        lookup = renderer.media_lookup({'items':[{'role':'current','shot_id':s['shot_id'],'temporary_prepared_path':f"/{s['shot_id']}.jpg"} for s in [detail,overview]]})
        plan = renderer.build_punchlist_update_plan(payload,lookup,'11/05/2026',{}, {})
        self.assertEqual(plan['pages'][0]['cover_shot_id'],'overview')

    def test_flagged_overview_still_beats_an_unflagged_detail_and_missing_overview_falls_back(self) -> None:
        payload = validation()
        detail = payload["inputs"]["ordered_shots"][0]
        overview = {**detail, "shot_id": "flagged-overview", "detail_type": "Overview"}
        payload["inputs"]["ordered_shots"] = [detail, overview]
        lookup = renderer.media_lookup({"items": [{"role": "current", "shot_id": item["shot_id"],
            "temporary_prepared_path": f"/{item['shot_id']}.jpg"} for item in [detail, overview]]})
        self.assertEqual("flagged-overview", renderer.cover_photo_entry(payload, lookup)["shot_id"])
        lookup.by_role_shot.pop(("current", "flagged-overview"))
        self.assertEqual(CURRENT_SHOT_ID, renderer.cover_photo_entry(payload, lookup)["shot_id"])
        self.assertIsNone(renderer.cover_photo_entry(payload, media_lookup()))

    def test_comparison_keeps_each_photos_own_message_and_repeats_unchanged_text(self) -> None:
        for original, updated in [('Broken downspout','Repaired downspout'), ('Same note','Same note')]:
            with self.subTest(original=original,updated=updated):
                payload = validation()
                payload['inputs']['ordered_shots'][0]['flagged_reason'] = updated
                item = payload['comparisons']['items'][0]
                item['previous_shot'] = dict(shot_id=PREVIOUS_SHOT_ID,session_id=item['previous_session_id'],flagged_reason=original)
                plan = renderer.build_comparison_plan(payload,media_lookup(),'11/05/2026',{}, {})
                page = next(p for p in plan['pages'] if p['kind']=='comparison_photo')
                slots = {slot['role']:slot['entry'] for slot in page['slots']}
                self.assertEqual(slots['previous']['flagged_reason'],original)
                self.assertEqual(slots['current']['flagged_reason'],updated)

    def test_missing_previous_note_does_not_borrow_current_note(self) -> None:
        payload = validation()
        plan = renderer.build_comparison_plan(payload,media_lookup(),'11/05/2026',{}, {})
        page = next(p for p in plan['pages'] if p['kind']=='comparison_photo')
        previous = next(s['entry'] for s in page['slots'] if s['role']=='previous')
        self.assertIsNone(previous['flagged_reason'])

    def test_comparison_rejects_mismatched_historical_photo_metadata(self) -> None:
        for changed in [{'shot_id':'different-photo'},{'session_id':'different-session'},{'issue_id':'different-issue'}]:
            payload = validation()
            payload['inputs']['ordered_shots'][0]['issue_id']='issue'
            item=payload['comparisons']['items'][0]
            item['previous_shot'] = dict(shot_id=PREVIOUS_SHOT_ID,session_id=item['previous_session_id'],issue_id='issue',flagged_reason='Original')
            item['previous_shot'].update(changed)
            with self.assertRaises(renderer.Phase2BError):
                renderer.build_comparison_plan(payload,media_lookup(),'11/05/2026',{}, {})

    def test_current_photo_plans_preserve_original_and_updated_messages(self) -> None:
        payload = validation()
        payload['inputs']['ordered_shots'][0]['original_flagged_reason'] = 'Original issue'
        for builder in (renderer.build_property_plan,renderer.build_priority_plan):
            plan=builder(payload,media_lookup(),'11/05/2026',{}, {})
            entries=[s['entry'] for p in plan['pages'] for s in p.get('slots',[])]
            self.assertEqual(entries[0]['original_flagged_reason'],'Original issue')
            self.assertEqual(entries[0]['flagged_reason'],'Paint touched up')

    def test_actor_email_from_snapshot_is_not_rendered_in_report_plans(self) -> None:
        payload = validation()
        payload["inputs"]["session"]["capturedByEmail"] = "former@example.com"
        payload["inputs"]["session"]["actorEmail"] = "former@example.com"
        payload["inputs"]["ordered_shots"][0]["capturedByEmail"] = "former@example.com"
        for builder in (
            renderer.build_property_plan,
            renderer.build_priority_plan,
            renderer.build_comparison_plan,
        ):
            plan = builder(payload, media_lookup(), "09/22/2026", {}, {})
            self.assertNotIn("former@example.com", json.dumps(plan))

    def test_pending_review_status_takes_precedence_over_capture_kind(self) -> None:
        self.assertEqual(
            "pending_review",
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

    def test_property_priority_and_comparison_plans_keep_pending_current_photo(self) -> None:
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
        self.assertEqual("pending_review", property_slots[0]["entry"]["visual_state"])

        priority_plan = renderer.build_priority_plan(payload, lookup, "09/22/2026", logo, weather)
        priority_slots = [
            slot
            for page in priority_plan["pages"]
            if page.get("kind") == "priority_photo"
            for slot in page.get("slots", [])
        ]
        self.assertEqual("pending_review", priority_slots[0]["entry"]["visual_state"])

        comparison_plan = renderer.build_comparison_plan(payload, lookup, "09/22/2026", logo, weather)
        comparison_page = next(page for page in comparison_plan["pages"] if page.get("kind") == "comparison_photo")
        slots_by_role = {slot["role"]: slot for slot in comparison_page["slots"]}
        self.assertEqual("pending_review", slots_by_role["current"]["entry"]["visual_state"])
        self.assertEqual("flagged", slots_by_role["previous"]["entry"]["visual_state"])

    def test_photo_page_draw_recomputes_pending_border_and_caption_state(self) -> None:
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

        self.assertEqual([{"state": "pending_review", "border": renderer.STATE_BORDER_COLORS["pending_review"]}], calls)
        self.assertEqual([{"state": "pending_review", "priority": "high"}], metadata_states)

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
                "caption_rect": {"x": 1, "y": 2, "width": 255, "height": 80},
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
                            "issueStatus": "resolved",
                            "captureKind": "resolvedCapture",
                            "isFlagged": True,
                            "flagged_reason": "Paint touched up",
                            "media_path": str(RENDERER_PATH),
                        },
                    },
                    {
                        **base_slot,
                        "role": "previous",
                        "entry": {
                            "caption": "Previous",
                            "visual_state": "flagged",
                            "flagged_reason": "Paint touched up",
                            "media_path": str(RENDERER_PATH),
                        },
                    },
                ],
            }

            renderer.draw_comparison_page(
                MagicMock(),
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
