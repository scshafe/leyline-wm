# Frame geometry primitives.
#
# A "frame" is a rectangle: {x, y, w, h}. All helpers here are pure
# math — no opinions about layout semantics live in this file.
#
# Default tolerance (pixels) for "close enough" comparisons. Override per-call
# by passing a different value in the optional $tol argument, or globally by
# exporting LEYLINE_FRAME_TOL before invoking wm (the legacy LEYLINE_YABAI_FRAME_TOL is
# still honored as a fallback). Nothing in-repo exports either, so the "4"
# fallback is the effective default everywhere.

def TOL: (env.LEYLINE_FRAME_TOL // env.LEYLINE_YABAI_FRAME_TOL // "4") | tonumber;

def fabs($x): if $x < 0 then -$x else $x end;

def frame_min_x($f): $f.x // 0;
def frame_min_y($f): $f.y // 0;
def frame_max_x($f): ($f.x // 0) + ($f.w // 0);
def frame_max_y($f): ($f.y // 0) + ($f.h // 0);

def frame_mid_x($f): ($f.x // 0) + ($f.w // 0) / 2;
def frame_mid_y($f): ($f.y // 0) + ($f.h // 0) / 2;

def frame_contains_x($f; $x):
  frame_min_x($f) <= $x and $x < frame_max_x($f);

def frame_contains_y($f; $y):
  frame_min_y($f) <= $y and $y < frame_max_y($f);

def frame_overlap_x($a; $b):
  ([frame_max_x($a), frame_max_x($b)] | min) -
  ([frame_min_x($a), frame_min_x($b)] | max)
  | if . < 0 then 0 else . end;

def frame_overlap_y($a; $b):
  ([frame_max_y($a), frame_max_y($b)] | min) -
  ([frame_min_y($a), frame_min_y($b)] | max)
  | if . < 0 then 0 else . end;

# Perpendicular distance from a frame's range to a coordinate.
# 0 if the coordinate is inside the range.
def frame_dist_x($f; $x):
  if $x < frame_min_x($f) then frame_min_x($f) - $x
  elif $x >= frame_max_x($f) then $x - frame_max_x($f)
  else 0 end;

def frame_dist_y($f; $y):
  if $y < frame_min_y($f) then frame_min_y($f) - $y
  elif $y >= frame_max_y($f) then $y - frame_max_y($f)
  else 0 end;

def frame_eq($a; $b; $tol):
  fabs(($a.x // 0) - ($b.x // 0)) <= $tol and
  fabs(($a.y // 0) - ($b.y // 0)) <= $tol and
  fabs(($a.w // 0) - ($b.w // 0)) <= $tol and
  fabs(($a.h // 0) - ($b.h // 0)) <= $tol;
def frame_eq($a; $b): frame_eq($a; $b; TOL);

# Bounding union of an array of frames. Null on empty.
def frames_union($arr):
  if ($arr | length) == 0 then null
  else
    reduce $arr[] as $f (
      null;
      if . == null then
        {x: ($f.x // 0), y: ($f.y // 0),
         w: ($f.w // 0), h: ($f.h // 0)}
      else
        ([.x, ($f.x // 0)] | min) as $nx
        | ([.y, ($f.y // 0)] | min) as $ny
        | ([(.x + .w), (($f.x // 0) + ($f.w // 0))] | max) as $nr
        | ([(.y + .h), (($f.y // 0) + ($f.h // 0))] | max) as $nb
        | {x: $nx, y: $ny, w: ($nr - $nx), h: ($nb - $ny)}
      end
    )
  end;

# Shrink a frame inward by $g on every side (a uniform inset). The layout-gap
# primitive: insetting a tiling region by the border width carves the OUTER gap,
# and the gap between split children is the INNER gap (parcel.jq split_slots). w/h
# are clamped ≥ 0 so an over-wide gap on a tiny rect yields a degenerate-but-valid
# frame rather than a negative one. Null in → null out.
def inset_frame($f; $g):
  if $f == null then null
  else { x: (($f.x // 0) + $g), y: (($f.y // 0) + $g),
         w: ([(($f.w // 0) - 2 * $g), 0] | max),
         h: ([(($f.h // 0) - 2 * $g), 0] | max) }
  end;

# Assign a window frame to the display that best holds it — the rectangle-fit
# primitive the autotile per-display tiling (D) needs to home each window before
# building its display's subtree. Policy:
#   • max area-overlap with each display's USABLE rect (menu-bar/Dock subtracted);
#   • a window that overlaps NO usable rect (clamped wholly into an inter-display
#     dead zone) falls back to max overlap against display FRAMES;
#   • ties (incl. the all-zero "fully off-screen" case) break to the LOWEST id.
# Never null when $displays is non-empty: every window lands on some display, so
# sync can always place it. $displays = norm_topology .displays =
#   [ { id, frame:{x,y,w,h}, usable:{x,y,w,h} } ... ].
def assign_display($win; $displays):
  if ($displays | length) == 0 then null
  else
    ( [ $displays[]
        | { id, ov: (frame_overlap_x($win; .usable) * frame_overlap_y($win; .usable)) } ]
    ) as $by_usable
    | ( if any($by_usable[]; .ov > 0)
        then $by_usable
        else [ $displays[]
               | { id, ov: (frame_overlap_x($win; .frame) * frame_overlap_y($win; .frame)) } ]
        end ) as $cands
    # max overlap, ties → lowest id (sort ascending on [−ov, id]; take first)
    | ( $cands | sort_by([ (.ov * -1), .id ]) | .[0].id )
  end;

# Map an axis label ("h"/"v") to the perpendicular coordinate axis.
# Used by tree.jq for spatial descent.
def perp_coord_axis($axis):
  if $axis == "h" then "y" else "x" end;
