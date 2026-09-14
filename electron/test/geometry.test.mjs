import assert from "node:assert/strict";
import test from "node:test";
import {
  HoverState,
  badgeBounds,
  clampBounds,
  containsPoint,
  previewCardBounds,
  previewPlacement,
  selectWorkArea,
  snapBounds,
} from "../src/geometry.mjs";

test("preview grows right and below at the top-left edge without moving the icon", () => {
  const placement = previewPlacement(
    { x: 72, y: 72 },
    { x: 0, y: 0, width: 1_440, height: 900 },
  );
  assert.equal(placement.horizontal, "right");
  assert.equal(placement.vertical, "below");
  assert.deepEqual(placement.bounds, { x: 8, y: 8, width: 330, height: 240 });
});

test("preview grows left and above at the bottom-right edge without moving the icon", () => {
  const placement = previewPlacement(
    { x: 1_432, y: 892 },
    { x: 0, y: 0, width: 1_440, height: 900 },
  );
  assert.equal(placement.horizontal, "left");
  assert.equal(placement.vertical, "above");
  assert.deepEqual(placement.bounds, { x: 1_102, y: 652, width: 330, height: 240 });
});

test("preview chooses the side with more room when neither direction fully fits", () => {
  const placement = previewPlacement(
    { x: 260, y: 200 },
    { x: 0, y: 0, width: 400, height: 300 },
  );
  assert.equal(placement.horizontal, "left");
  assert.equal(placement.vertical, "above");
  assert.deepEqual(placement.bounds, { x: 8, y: 8, width: 330, height: 240 });
});

test("clamp and snap honor a negative-coordinate display work area", () => {
  const area = { x: -1_920, y: -120, width: 1_920, height: 1_080 };
  assert.deepEqual(
    clampBounds({ x: -2_100, y: -300, width: 64, height: 64 }, area),
    { x: -1_912, y: -112, width: 64, height: 64 },
  );
  assert.deepEqual(
    snapBounds({ x: -75, y: 870, width: 64, height: 64 }, area),
    { x: -76, y: 884, width: 64, height: 64 },
  );
});

test("display selection prefers overlap and otherwise the nearest display", () => {
  const displays = [
    { workArea: { x: 0, y: 0, width: 1_000, height: 800 } },
    { workArea: { x: 1_000, y: 0, width: 1_000, height: 800 } },
  ];
  assert.deepEqual(selectWorkArea({ x: 1_100, y: 50, width: 64, height: 64 }, displays), displays[1].workArea);
  assert.deepEqual(selectWorkArea({ x: 2_100, y: 50, width: 64, height: 64 }, displays), displays[1].workArea);
});

test("hover opens only after badge dwell and closes only after leave grace", () => {
  const hover = new HoverState();
  assert.equal(hover.update({ now: 0, overBadge: false, insidePreview: true, isPreview: false }), null);
  assert.equal(hover.update({ now: 1_000, overBadge: true, insidePreview: true, isPreview: false }), null);
  assert.equal(hover.update({ now: 1_179, overBadge: true, insidePreview: true, isPreview: false }), null);
  assert.equal(hover.update({ now: 1_180, overBadge: true, insidePreview: true, isPreview: false }), "preview");
  assert.equal(hover.update({ now: 2_000, overBadge: false, insidePreview: true, isPreview: true }), null);
  assert.equal(hover.update({ now: 3_000, overBadge: false, insidePreview: false, isPreview: true }), null);
  assert.equal(hover.update({ now: 3_249, overBadge: false, insidePreview: false, isPreview: true }), null);
  assert.equal(hover.update({ now: 3_250, overBadge: false, insidePreview: false, isPreview: true }), "icon");
});

test("hover reset discards a pending preview transition", () => {
  const hover = new HoverState();
  hover.update({ now: 0, overBadge: true, insidePreview: false, isPreview: false });
  hover.reset();
  assert.equal(hover.update({ now: 500, overBadge: true, insidePreview: false, isPreview: false }), null);
});

test("native hit regions match the badge and edge-aware preview card", () => {
  const badge = badgeBounds({ x: 100, y: 200, width: 64, height: 64 }, 125);
  assert.deepEqual(badge, { x: 130, y: 200, width: 34, height: 23 });
  assert.equal(containsPoint(badge, { x: 130, y: 200 }), true);
  assert.equal(containsPoint(badge, { x: 129, y: 200 }), false);
  assert.deepEqual(
    previewCardBounds({ x: 100, y: 200, width: 330, height: 240 }, "below"),
    { x: 107, y: 252, width: 316, height: 181 },
  );
});
