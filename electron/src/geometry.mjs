export const ICON_SIZE = 64;
export const FOCUS_SIZE = Object.freeze({ width: 330, height: 76 });
export const PREVIEW_SIZE = Object.freeze({ width: 330, height: 240 });
export const WINDOW_MARGIN = 8;
export const SNAP_INSET = 12;
export const SNAP_THRESHOLD = 40;

function finite(value, fallback = 0) {
  return Number.isFinite(value) ? value : fallback;
}

export function normalizeBounds(value, fallback = { x: 0, y: 0, width: 0, height: 0 }) {
  const source = value && typeof value === "object" ? value : {};
  return {
    x: finite(source.x, fallback.x),
    y: finite(source.y, fallback.y),
    width: Math.max(0, finite(source.width, fallback.width)),
    height: Math.max(0, finite(source.height, fallback.height)),
  };
}

export function containsPoint(bounds, point) {
  const rect = normalizeBounds(bounds);
  const x = finite(point?.x, Number.NaN);
  const y = finite(point?.y, Number.NaN);
  return x >= rect.x && x <= rect.x + rect.width && y >= rect.y && y <= rect.y + rect.height;
}

export function intersectionArea(first, second) {
  const a = normalizeBounds(first);
  const b = normalizeBounds(second);
  const width = Math.max(0, Math.min(a.x + a.width, b.x + b.width) - Math.max(a.x, b.x));
  const height = Math.max(0, Math.min(a.y + a.height, b.y + b.height) - Math.max(a.y, b.y));
  return width * height;
}

function distanceToRectSquared(point, bounds) {
  const rect = normalizeBounds(bounds);
  const dx = Math.max(rect.x - point.x, 0, point.x - (rect.x + rect.width));
  const dy = Math.max(rect.y - point.y, 0, point.y - (rect.y + rect.height));
  return dx * dx + dy * dy;
}

export function selectWorkArea(bounds, displays) {
  const rect = normalizeBounds(bounds);
  const candidates = (Array.isArray(displays) ? displays : [])
    .map((display) => display?.workArea ?? display?.bounds ?? display)
    .filter((area) => area && Number.isFinite(area.x) && Number.isFinite(area.y)
      && Number.isFinite(area.width) && Number.isFinite(area.height));
  if (candidates.length === 0) return null;

  let selected = candidates[0];
  let bestIntersection = intersectionArea(rect, selected);
  let bestDistance = Number.POSITIVE_INFINITY;
  const center = { x: rect.x + rect.width / 2, y: rect.y + rect.height / 2 };
  if (bestIntersection === 0) bestDistance = distanceToRectSquared(center, selected);

  for (const area of candidates.slice(1)) {
    const overlap = intersectionArea(rect, area);
    if (overlap > bestIntersection) {
      selected = area;
      bestIntersection = overlap;
      bestDistance = overlap === 0 ? distanceToRectSquared(center, area) : 0;
      continue;
    }
    if (overlap === bestIntersection && overlap === 0) {
      const distance = distanceToRectSquared(center, area);
      if (distance < bestDistance) {
        selected = area;
        bestDistance = distance;
      }
    }
  }
  return normalizeBounds(selected);
}

export function clampBounds(bounds, workArea, margin = WINDOW_MARGIN) {
  const rect = normalizeBounds(bounds);
  const area = normalizeBounds(workArea);
  const inset = Math.max(0, finite(margin));
  const minimumX = area.x + inset;
  const minimumY = area.y + inset;
  const maximumX = area.x + area.width - rect.width - inset;
  const maximumY = area.y + area.height - rect.height - inset;
  return {
    ...rect,
    x: maximumX < minimumX ? minimumX : Math.max(minimumX, Math.min(rect.x, maximumX)),
    y: maximumY < minimumY ? minimumY : Math.max(minimumY, Math.min(rect.y, maximumY)),
  };
}

export function snapBounds(bounds, workArea, threshold = SNAP_THRESHOLD, inset = SNAP_INSET) {
  const rect = clampBounds(bounds, workArea, WINDOW_MARGIN);
  const area = normalizeBounds(workArea);
  const distance = Math.max(0, finite(threshold));
  const edgeInset = Math.max(0, finite(inset));
  const leftDistance = Math.abs(rect.x - area.x);
  const rightDistance = Math.abs(area.x + area.width - (rect.x + rect.width));
  const topDistance = Math.abs(rect.y - area.y);
  const bottomDistance = Math.abs(area.y + area.height - (rect.y + rect.height));

  if (Math.min(leftDistance, rightDistance) < distance) {
    rect.x = leftDistance <= rightDistance
      ? area.x + edgeInset
      : area.x + area.width - rect.width - edgeInset;
  }
  if (Math.min(topDistance, bottomDistance) < distance) {
    rect.y = topDistance <= bottomDistance
      ? area.y + edgeInset
      : area.y + area.height - rect.height - edgeInset;
  }
  return clampBounds(rect, area, edgeInset);
}

export function anchorFromIconBounds(iconBounds) {
  const icon = normalizeBounds(iconBounds, { x: 0, y: 0, width: ICON_SIZE, height: ICON_SIZE });
  return { x: icon.x + icon.width, y: icon.y + icon.height };
}

export function iconBoundsFromAnchor(anchor) {
  return {
    x: finite(anchor?.x) - ICON_SIZE,
    y: finite(anchor?.y) - ICON_SIZE,
    width: ICON_SIZE,
    height: ICON_SIZE,
  };
}

export function previewPlacement(anchor, workArea, options = {}) {
  const area = normalizeBounds(workArea);
  const margin = Math.max(0, finite(options.margin, WINDOW_MARGIN));
  const iconSize = Math.max(1, finite(options.iconSize, ICON_SIZE));
  const width = Math.max(iconSize, finite(options.width, PREVIEW_SIZE.width));
  const height = Math.max(iconSize, finite(options.height, PREVIEW_SIZE.height));
  const right = finite(anchor?.x);
  const bottom = finite(anchor?.y);
  const iconLeft = right - iconSize;
  const iconTop = bottom - iconSize;
  const areaRight = area.x + area.width;
  const areaBottom = area.y + area.height;

  const fitsLeft = right - width >= area.x + margin;
  const fitsRight = iconLeft + width <= areaRight - margin;
  let horizontal;
  if (fitsLeft || !fitsRight) {
    const roomLeft = right - area.x;
    const roomRight = areaRight - iconLeft;
    horizontal = fitsLeft || roomLeft >= roomRight ? "left" : "right";
  } else {
    horizontal = "right";
  }

  const fitsAbove = bottom - height >= area.y + margin;
  const fitsBelow = iconTop + height <= areaBottom - margin;
  let vertical;
  if (fitsAbove || !fitsBelow) {
    const roomAbove = bottom - area.y;
    const roomBelow = areaBottom - iconTop;
    vertical = fitsAbove || roomAbove >= roomBelow ? "above" : "below";
  } else {
    vertical = "below";
  }

  const bounds = {
    x: horizontal === "left" ? right - width : iconLeft,
    y: vertical === "above" ? bottom - height : iconTop,
    width,
    height,
  };
  return { bounds: clampBounds(bounds, area, margin), horizontal, vertical };
}

export function badgeBounds(iconBounds, count) {
  const icon = normalizeBounds(iconBounds);
  const digits = String(Math.max(0, Math.trunc(finite(count)))).length;
  const width = Math.max(23, digits * 6 + 16);
  return { x: icon.x + icon.width - width, y: icon.y, width, height: 23 };
}

export function previewCardBounds(previewBounds, vertical) {
  const preview = normalizeBounds(previewBounds);
  return {
    x: preview.x + 7,
    y: preview.y + (vertical === "below" ? 52 : 7),
    width: Math.max(0, preview.width - 14),
    height: Math.max(0, preview.height - 59),
  };
}

export class HoverState {
  constructor({ dwellMs = 180, leaveGraceMs = 250 } = {}) {
    this.dwellMs = dwellMs;
    this.leaveGraceMs = leaveGraceMs;
    this.reset();
  }

  reset() {
    this.pendingPreview = null;
    this.deadline = 0;
  }

  update({ now, overBadge, insidePreview, isPreview }) {
    const wantsPreview = isPreview ? Boolean(insidePreview) : Boolean(overBadge);
    if (wantsPreview === Boolean(isPreview)) {
      this.reset();
      return null;
    }
    if (this.pendingPreview !== wantsPreview) {
      this.pendingPreview = wantsPreview;
      this.deadline = finite(now) + (wantsPreview ? this.dwellMs : this.leaveGraceMs);
    }
    if (finite(now) < this.deadline) return null;
    this.reset();
    return wantsPreview ? "preview" : "icon";
  }
}
