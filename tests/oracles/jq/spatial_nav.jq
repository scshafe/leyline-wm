import "geometry" as G;
import "bool_helpers" as B;

# Spatial-navigation ranking. Single source of truth for "given a
# source frame and a direction, which candidate wins?" — consumed by
# shell, jq tests, the Swift menu, and the runtime via the same
# rank_candidates entry point.
#
# Conforms to the contract in
# docs/contracts/spatial-nav-algorithm-spec.md.
#
# Geometry primitives live in geometry.jq; this module imports them.
# This module knows nothing about Spaces, Stage Manager, or float
# vs. tiled — those are visibility / membership questions answered
# upstream by the caller.

# -- Direction helpers ------------------------------------------------

def signed_gap($dir; $src; $dst):
  if   $dir == "east"  then ($dst.x // 0) - (($src.x // 0) + ($src.w // 0))
  elif $dir == "west"  then ($src.x // 0) - (($dst.x // 0) + ($dst.w // 0))
  elif $dir == "south" then ($dst.y // 0) - (($src.y // 0) + ($src.h // 0))
  elif $dir == "north" then ($src.y // 0) - (($dst.y // 0) + ($dst.h // 0))
  else 0 end;

# Strictly on the far side of source's direction-facing edge. Equality
# counts (touching edges count as "beyond").
def side_in_direction($dir; $src; $dst):
  signed_gap($dir; $src; $dst) >= 0;

def perpendicular_overlap($dir; $src; $dst):
  if $dir == "east" or $dir == "west"
  then G::frame_overlap_y($src; $dst)
  else G::frame_overlap_x($src; $dst)
  end;

def perpendicular_centerline_distance($dir; $src; $dst):
  if $dir == "east" or $dir == "west"
  then G::fabs(G::frame_mid_y($src) - G::frame_mid_y($dst))
  else G::fabs(G::frame_mid_x($src) - G::frame_mid_x($dst))
  end;

# Length of the candidate's edge along the perpendicular axis — the
# divisor for border_proportion.
def border_length($dir; $frame):
  if $dir == "east" or $dir == "west" then ($frame.h // 0)
  else ($frame.w // 0)
  end;

# -- Aggregate surface ------------------------------------------------

def max_display_w($displays):
  ([ $displays[]?  | (.frame.w // 0) ] | max) // 0;

def max_display_h($displays):
  ([ $displays[]?  | (.frame.h // 0) ] | max) // 0;

# Per-direction "opposite-edge band": a rect along the surface edge
# opposite the travel direction, with depth equal to the largest
# display extent on the wrap axis. The depth guarantees the band
# fully contains at least one display.
def opposite_edge_band($dir; $union; $displays):
  if $union == null then null
  elif $dir == "west" then
    # candidate must come from the east edge band (the rightmost slice)
    (max_display_w($displays)) as $depth
    | {x: ($union.x + $union.w - $depth), y: $union.y, w: $depth, h: $union.h}
  elif $dir == "east" then
    # candidate must come from the west edge band (the leftmost slice)
    (max_display_w($displays)) as $depth
    | {x: $union.x, y: $union.y, w: $depth, h: $union.h}
  elif $dir == "north" then
    # candidate must come from the south edge band (the bottommost slice)
    (max_display_h($displays)) as $depth
    | {x: $union.x, y: ($union.y + $union.h - $depth), w: $union.w, h: $depth}
  elif $dir == "south" then
    # candidate must come from the north edge band (the topmost slice)
    (max_display_h($displays)) as $depth
    | {x: $union.x, y: $union.y, w: $union.w, h: $depth}
  else null end;

def aggregate_surface($displays):
  ($displays // []) as $ds
  | G::frames_union([ $ds[] | .frame ]) as $union
  | {
      displays: $ds,
      union_frame: $union,
      opposite_edge_bands: {
        north: opposite_edge_band("north"; $union; $ds),
        east:  opposite_edge_band("east";  $union; $ds),
        south: opposite_edge_band("south"; $union; $ds),
        west:  opposite_edge_band("west";  $union; $ds)
      }
    };

def frames_intersect($a; $b):
  $a != null and $b != null
  and G::frame_overlap_x($a; $b) > 0
  and G::frame_overlap_y($a; $b) > 0;

def frame_in_opposite_edge_band($dir; $frame; $surface):
  ($surface.opposite_edge_bands[$dir] // null) as $band
  | $band != null and frames_intersect($frame; $band);

# -- Tiebreak ---------------------------------------------------------

# Centerline distance is the sole secondary geometry policy. Window id remains
# the deterministic final key in sort_key.
def tiebreak_value($dir; $src; $dst):
  perpendicular_centerline_distance($dir; $src; $dst);

# -- Scoring ----------------------------------------------------------

def direct_edge_distance($dir; $src; $dst):
  signed_gap($dir; $src; $dst);

# Wrap edge distance: how deep into the opposite-edge band the
# candidate sits, measured from the surface's far edge to the
# candidate's edge on the same far side. Smaller = closer to the
# surface's actual edge = ranks first.
def wrap_edge_distance($dir; $dst; $surface):
  ($surface.union_frame // null) as $u
  | if $u == null then 0
    elif $dir == "west"  then ($u.x + $u.w) - ($dst.x + $dst.w)
    elif $dir == "east"  then ($dst.x) - ($u.x)
    elif $dir == "north" then ($u.y + $u.h) - ($dst.y + $dst.h)
    elif $dir == "south" then ($dst.y) - ($u.y)
    else 0
    end;

def border_proportion($dir; $dst; $perp_overlap):
  border_length($dir; $dst) as $bl
  | if $bl <= 0 then 0
    else 1 - ($perp_overlap / $bl)
    end;

def score_direct($dir; $src; $cand; $opts):
  perpendicular_overlap($dir; $src; $cand.frame) as $po
  | {
      edge_distance:         direct_edge_distance($dir; $src; $cand.frame),
      perpendicular_overlap: $po,
      border_proportion:     border_proportion($dir; $cand.frame; $po),
      tiebreak_value:        tiebreak_value($dir; $src; $cand.frame)
    };

def score_wrap($dir; $src; $cand; $surface; $opts):
  perpendicular_overlap($dir; $src; $cand.frame) as $po
  | {
      edge_distance:         wrap_edge_distance($dir; $cand.frame; $surface),
      perpendicular_overlap: $po,
      border_proportion:     border_proportion($dir; $cand.frame; $po),
      tiebreak_value:        tiebreak_value($dir; $src; $cand.frame)
    };

# Sort tuple: (edge_distance asc, perpendicular_overlap desc,
# border_proportion asc, tiebreak_value asc, id asc).
def sort_key:
  [
    (.score.edge_distance // 0),
    -((.score.perpendicular_overlap // 0)),
    (.score.border_proportion // 0),
    (.score.tiebreak_value // 0),
    (.id // 0)
  ];

def with_rank:
  to_entries | map(.value + {rank: .key});

# -- Viability --------------------------------------------------------

# `allow_zero_perpendicular_overlap` exists to preserve the legacy
# display-graph behavior (zero perpendicular overlap counts as a
# neighbor). Default false matches the algorithm spec's strict > 0.
def overlap_predicate($po; $opts):
  if ($opts.allow_zero_perpendicular_overlap // false)
  then $po >= 0
  else $po > 0
  end;

def viable_direct($dir; $src; $cand; $opts):
  side_in_direction($dir; $src; $cand.frame)
  and overlap_predicate(perpendicular_overlap($dir; $src; $cand.frame); $opts);

def viable_wrap($dir; $src; $cand; $surface; $opts):
  frame_in_opposite_edge_band($dir; $cand.frame; $surface)
  and overlap_predicate(perpendicular_overlap($dir; $src; $cand.frame); $opts);

# -- Candidate filtering ----------------------------------------------

# The algorithm spec assumes the caller already restricted candidates
# to (visible AND non-source). We mirror that contract here so callers
# can pass in raw window lists without pre-filtering. Opt out via
# $opts.skip_filter for callers that already filtered (e.g., the
# display_graph migration, where candidates are displays, not windows).
def filter_visible($source_id; $candidates; $opts):
  if ($opts.skip_filter // false) then $candidates
  else
    [ $candidates[]
      | select(($source_id == null) or ((.id // null) != $source_id))
      | select(B::bool_field(.; "is-visible";   "is_visible";   true)  == true)
      | select(B::bool_field(.; "is-minimized"; "is_minimized"; false) != true)
    ]
  end;

# -- Main entry -------------------------------------------------------

# rank_candidates($source_frame; $direction; $candidates; $opts) returns:
#
#   {
#     direction:  <dir>,
#     outcome:    "direct" | "wrap" | "noCandidate",
#     candidates: [ {id, frame, ...passthrough, score, rank} ],
#     winner:     <candidate or null>
#   }
#
# $opts is optional and may contain:
#   - source_id: <id>          to drop self from candidates
#   - surface: <aggregate>     precomputed; saves recompute
#   - surface_displays: [...]  used to build surface if .surface absent
#   - skip_filter: bool        skip visibility filtering
#   - skip_wrap: bool          skip Phase B; never returns "wrap"
#   - allow_zero_perpendicular_overlap: bool
#                              relaxes viability (display-graph compat)
def rank_candidates($source_frame; $direction; $candidates; $opts):
  ($opts // {}) as $o
  | (if   $o.surface          then $o.surface
     elif $o.surface_displays then aggregate_surface($o.surface_displays)
     else aggregate_surface([])
     end) as $surface
  | filter_visible(($o.source_id // null); $candidates; $o) as $cands
  | ( [ $cands[]
        | select(viable_direct($direction; $source_frame; .; $o))
        | . + {score: score_direct($direction; $source_frame; .; $o)}
      ]
      | sort_by(sort_key)
      | with_rank
    ) as $direct
  | if ($direct | length) > 0 then
      { direction: $direction,
        outcome: "direct",
        candidates: $direct,
        winner: $direct[0] }
    elif ($o.skip_wrap // false) then
      { direction: $direction,
        outcome: "noCandidate",
        candidates: [],
        winner: null }
    else
      ( [ $cands[]
          | select(viable_wrap($direction; $source_frame; .; $surface; $o))
          | . + {score: score_wrap($direction; $source_frame; .; $surface; $o)}
        ]
        | sort_by(sort_key)
        | with_rank
      ) as $wrap
      | if ($wrap | length) > 0 then
          { direction: $direction,
            outcome: "wrap",
            candidates: $wrap,
            winner: $wrap[0] }
        else
          { direction: $direction,
            outcome: "noCandidate",
            candidates: [],
            winner: null }
        end
    end;

# Convenience: rank all four directions in one pass against the same
# source + candidate set. Reuses one surface. Returns:
#   { source, results: { north: ..., east: ..., south: ..., west: ... } }
# where each direction matches the rank_candidates output shape.
def rank_all_directions($source_frame; $candidates; $opts):
  ($opts // {}) as $o
  | (if   $o.surface          then $o.surface
     elif $o.surface_displays then aggregate_surface($o.surface_displays)
     else aggregate_surface([])
     end) as $surface
  | ($o + {surface: $surface}) as $o2
  | {
      source_frame: $source_frame,
      results: {
        north: rank_candidates($source_frame; "north"; $candidates; $o2),
        east:  rank_candidates($source_frame; "east";  $candidates; $o2),
        south: rank_candidates($source_frame; "south"; $candidates; $o2),
        west:  rank_candidates($source_frame; "west";  $candidates; $o2)
      }
    };
