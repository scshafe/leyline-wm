# movemode.jq — pure helpers for the Hyper+m movement mode (movement-mode B3).
#
# drop_side($target_cell; $moved_frame; $display; $policy) — which side of the
# target cell should a staged drop occupy?
#
#   policy "aspect" (the DEFAULT, operator decision 2): pick the SPLIT AXIS whose
#     two resulting half-cells' aspect ratios (w/h) are nearest the display's
#     aspect ratio — compared in log space so 2:1 and 1:2 are equally far from
#     1:1 (scale-invariant). A v-split halves the width (sides east/west); an
#     h-split halves the height (sides north/south). TIE → the v-split axis
#     (pinned: columns are the wm's native grain). Within the axis, the HALF
#     nearest the moved window's pre-move centre wins (the tuck heuristic;
#     tie → the origin-near half: west / north).
#   policy "north"|"south"|"east"|"west": fixed pass-through.
#   anything else: treated as "aspect" (config files degrade, never error).
#
# $target_cell — {frame: {x,y,w,h}, ...} (an arrangement cell or any frame
#   carrier; only .frame is read). $moved_frame — the moved window's frame
#   {x,y,w,h} (its store frame — the pre-move position). $display — {frame:
#   {x,y,w,h}, ...} (the display the target cell lives on). All frames are
#   objects; callers normalize array frames first (P::norm_topology shape).
#
# rotate_side($side) — the Hyper+c clockwise rotation: n→e→s→w→n.
#
# half_select($neighbor_cell; $focused_frame; $display; $dir; $tol) — the DIRECTIONAL
#   tuck's 3-tier default-side rule (fork 2): focused window origin offset → nearest
#   display edge → leading half. See the def's own header. (The --into tuck arm keeps
#   drop_side's aspect policy — it is shared with the live Hyper+m drop-staging.)
#
# No imports: pure arithmetic on frames (keeps the read-only-lens guard clean
# by construction). Fixture-locked under parcel/fixtures/movemode/.

def rotate_side($side):
  {north: "east", east: "south", south: "west", west: "north"}[$side] // "north";

def drop_side($target_cell; $moved_frame; $display; $policy):
  if ($policy == "north" or $policy == "south" or $policy == "east" or $policy == "west")
  then $policy
  else
    ($target_cell.frame) as $tf
    | ($display.frame) as $df
    # log-space distance of each split's half-cell aspect from the display aspect
    | (($df.w / $df.h) | log) as $da
    | ((($tf.w / 2) / $tf.h) | log) as $va        # v-split half: w/2 × h
    | (($tf.w / ($tf.h / 2)) | log) as $ha        # h-split half: w × h/2
    | (if (($va - $da) | fabs) <= (($ha - $da) | fabs) then "v" else "h" end) as $axis
    | ($moved_frame // {}) as $mf
    | (if ($mf.x != null) and ($mf.w != null) then ($mf.x + ($mf.w / 2)) else null end) as $mcx
    | (if ($mf.y != null) and ($mf.h != null) then ($mf.y + ($mf.h / 2)) else null end) as $mcy
    | if $axis == "v"
      then (if ($mcx == null) or ($mcx <= ($tf.x + ($tf.w / 2))) then "west" else "east" end)
      else (if ($mcy == null) or ($mcy <= ($tf.y + ($tf.h / 2))) then "north" else "south" end)
      end
  end;

# half_select($neighbor_cell; $focused_frame; $display; $dir; $tol) — the DIRECTIONAL
# tuck's default-side rule (fork 2). When the focused window tucks into the $dir
# neighbor's cell, that cell splits PERPENDICULAR to the move (east/west tuck → the
# pair stacks vertically, halves north/south; north/south tuck → side-by-side, halves
# west/east). Choose the half by a layered rule:
#   (1) the focused WINDOW's ORIGIN along the perpendicular axis vs the neighbor cell's
#       perpendicular MIDPOINT — origin in the leading part → leading half, else trailing;
#   (2) tie (|origin − mid| ≤ $tol): nearer DISPLAY edge — origin vs the display midpoint
#       (above the midline → nearer the leading edge → leading half, else trailing);
#   (3) still perfectly symmetric (also within $tol): the LEADING half (north / west).
# The caller's --side overrides this entirely (tuck.sh consults auto_side only when --side
# is empty). $tol is passed in (G::TOL) to keep this file import-free; fabs is a builtin.
#
# ROBUST BY CONTRACT (adversarial fix): a null/missing $neighbor_cell.frame or
# $display.frame never divides-by-null — it degrades to the tier-3 LEADING half. This is
# what lets an explicit --side win even on a degenerate scene: a guarded helper cannot
# abort the resolver, so the tuck still succeeds. $neighbor_cell — {frame:{x,y,w,h}};
# $focused_frame — the moving window's store frame {x,y,w,h} (or null); $display —
# {frame:{x,y,w,h}} the cell's display; $dir — the cardinal tuck direction.
def half_select($neighbor_cell; $focused_frame; $display; $dir; $tol):
  ($neighbor_cell.frame) as $nf
  | ($display.frame) as $df
  | ($focused_frame // null) as $ff
  | if ($dir == "east" or $dir == "west")
    then
      # perpendicular axis = y; halves: north (leading) / south
      if ($nf == null) or ($nf.y == null) or ($nf.h == null) then "north"
      else
        (($nf.y) + ($nf.h / 2)) as $mid
        | (if ($ff != null and $ff.y != null) then $ff.y else $mid end) as $o
        | if ((($o - $mid) | fabs) > $tol) then (if $o <= $mid then "north" else "south" end)
          elif ($df != null and $df.y != null and $df.h != null)
            then ( (($df.y) + ($df.h / 2)) as $dmid
                   | if ((($o - $dmid) | fabs) > $tol) then (if $o <= $dmid then "north" else "south" end) else "north" end )
          else "north" end
      end
    else
      # perpendicular axis = x; halves: west (leading) / east
      if ($nf == null) or ($nf.x == null) or ($nf.w == null) then "west"
      else
        (($nf.x) + ($nf.w / 2)) as $mid
        | (if ($ff != null and $ff.x != null) then $ff.x else $mid end) as $o
        | if ((($o - $mid) | fabs) > $tol) then (if $o <= $mid then "west" else "east" end)
          elif ($df != null and $df.x != null and $df.w != null)
            then ( (($df.x) + ($df.w / 2)) as $dmid
                   | if ((($o - $dmid) | fabs) > $tol) then (if $o <= $dmid then "west" else "east" end) else "west" end )
          else "west" end
      end
    end;
