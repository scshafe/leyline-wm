# Pure frame-rectangle helpers.
#
# A "frame" is a rectangle: {x, y, w, h}. These primitives are pure
# math — they don't know about displays, migrations, or tiling. They
# accreted here as the shared frame-helpers home: the clamp/scale/
# min_size family was lifted from display_migration.jq once display
# migration, tiling normalization, and "clamp a frame inside bounds"
# all wanted it; the coercion pair (as_frame / round_frame) was later
# promoted out of parcel.jq once reconcile.jq and autotile.jq became
# consumers alongside the layout engine.
#
# Backward compatibility: display_migration.jq imports this module
# and re-exports the same names, so any caller still using
# `import "display_migration" as M; M::clamp_frame(...)` keeps
# working. New callers should import frame_ops directly:
#   import "frame_ops" as F;
#   F::clamp_frame($frame; $bounds; $min)
#
# Tolerance is not used here — these are exact-arithmetic helpers.
# Tolerance lives in geometry.jq (TOL, default 4px via LEYLINE_FRAME_TOL).

def number($v): ($v // 0 | tonumber? // 0);

def normalize_frame($frame):
  ($frame // {}) as $f
  | {
      x: number($f.x),
      y: number($f.y),
      w: number($f.w // $f.width),
      h: number($f.h // $f.height)
    };

# Coerce a frame from either an [x,y,w,h] ARRAY or an {x,y,w,h}/{width,height}
# OBJECT into {x,y,w,h}, passing null through as null. Distinct from
# normalize_frame: as_frame accepts arrays and preserves null (it is the
# topology/tree coercion the layout engine uses, where "no frame" is meaningful);
# normalize_frame is object-only, string-coercing, and never null (the migration
# math wants a concrete rect). Originally homed in parcel.jq; promoted here once
# reconcile.jq (and now autotile.jq) became additional consumers — frame_ops is
# the designated shared frame-helpers module.
def as_frame($v):
  if $v == null then null
  elif ($v | type) == "array"
  then {x: ($v[0] // 0), y: ($v[1] // 0), w: ($v[2] // 0), h: ($v[3] // 0)}
  else {x: ($v.x // 0), y: ($v.y // 0),
        w: ($v.w // $v.width // 0), h: ($v.h // $v.height // 0)} end;

# Round every component of a frame to the nearest integer; null passes through.
def round_frame($f):
  if $f == null then null
  else {x: ($f.x | round), y: ($f.y | round),
        w: ($f.w | round), h: ($f.h | round)} end;

# Read a "minimum size" record from a free-form opts hash. Accepts
# any of: {w,h} (preferred), {min_w,min_h}, {min_width,min_height}.
# Defaults: 160 x 120 (matches the previous migration default).
def min_size($opts):
  ($opts // {}) as $o
  | {
      w: number($o.w // $o.min_w // $o.min_width // 160),
      h: number($o.h // $o.min_h // $o.min_height // 120)
    };

def clamp_number($value; $lo; $hi):
  if $hi < $lo then $lo
  elif $value < $lo then $lo
  elif $value > $hi then $hi
  else $value end;

# Clamp $frame so it lies inside $bounds, with width/height
# floor at $minimum. Output integer-rounded.
#
# If $minimum is wider/taller than $bounds, the bounds win on the
# affected axis (the resulting frame can be smaller than min_size).
# This matches the historical behavior in display_migration.jq.
def clamp_frame($frame; $bounds; $minimum):
  normalize_frame($frame) as $f
  | normalize_frame($bounds) as $b
  | min_size($minimum) as $m
  | ([$b.w, ([$f.w, $m.w] | max)] | min) as $w
  | ([$b.h, ([$f.h, $m.h] | max)] | min) as $h
  | ($b.x + $b.w - $w) as $max_x
  | ($b.y + $b.h - $h) as $max_y
  | {
      x: (clamp_number($f.x; $b.x; $max_x) | round),
      y: (clamp_number($f.y; $b.y; $max_y) | round),
      w: ($w | round),
      h: ($h | round)
    };

def scale_position($value; $old_origin; $old_size; $new_origin; $new_size):
  if $old_size == 0 then $new_origin
  else $new_origin + (($value - $old_origin) * $new_size / $old_size)
  end;

def scale_length($value; $old_size; $new_size):
  if $old_size == 0 then $value
  else $value * $new_size / $old_size
  end;

# Map $frame from one work-area rectangle into another, preserving
# proportional position and size. Output is clamped to $new bounds
# with $minimum applied via clamp_frame.
def scale_frame_proportional($frame; $old_wm_work_area; $new_wm_work_area; $minimum):
  normalize_frame($frame) as $f
  | normalize_frame($old_wm_work_area) as $old
  | normalize_frame($new_wm_work_area) as $new
  | {
      x: scale_position($f.x; $old.x; $old.w; $new.x; $new.w),
      y: scale_position($f.y; $old.y; $old.h; $new.y; $new.h),
      w: scale_length($f.w; $old.w; $new.w),
      h: scale_length($f.h; $old.h; $new.h)
    }
  | clamp_frame(.; $new; $minimum);
