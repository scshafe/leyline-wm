# overlap.jq — max-overlap target resolution for the float→tile placement (Hyper+f).
#
# When Hyper+f re-tiles a FLOATING window, it should land where the float visually IS:
# split the tiled cell the float most overlaps (operator spec, 2026-06-17). This module
# is the pure picker; the split itself is the shipped `wm_parcel_insert <side> --fill`
# author (the single-cell carry-drop path), with the aspect side from MM::drop_side.
#
# max_overlap_target($arr; $float_frame)
#   $arr         — the live arrangement store ({segments, bindings, ...}); only .bindings
#                  is read. Each binding's .frame is the live PRESENTED cell rect (the same
#                  geometry movemode's drop_side resolution reads via $tb.value.frame, and
#                  what the user sees the float sitting over). A frame-less binding (a pre-
#                  settle / test store with no projected frames) is SKIPPED.
#   $float_frame — the floating window's live frame {x,y,w,h} (from observed).
#   → the BOUND cell to split, as { cell_key, window_id, frame }, chosen by the operator's
#     verbatim ladder:
#       1. greatest overlap AREA with $float_frame   (frame_overlap_x * frame_overlap_y)
#       2. tie → bigger cell           (larger frame area first)
#       3. tie → top                   (smaller frame.y first)
#       4. tie → left                  (smaller frame.x first)
#       5. tie → smaller cell_key      (a unique, always-present final key — makes the
#                                       result provably independent of binding insertion
#                                       order even for a perfect geometric tie; unreachable
#                                       under F1's no-overlap invariant, belt-and-suspenders)
#   → null when there is no bound cell to overlap (empty store) OR no cell overlaps at all
#     (the float sits wholly in a gap / off every tiled cell, incl. a different display —
#     an off-display cell has zero overlap by construction). The caller treats null as
#     "nothing to overlap" and falls back to the default sync-adopt.
#
# window_id resolves through a z-stack: .contents[0].window_id (the top) // .window_id, so
# the returned id is exactly what `wm_parcel_insert --focused {window_id}` resolves to a
# cell. Stack non-top members (.contents[1:] / .off_top) are never their own bindings, so
# they are correctly not candidates. PURE — geometry only (guard-clean, revert-by-deletion).

import "geometry" as G;

def max_overlap_target($arr; $float_frame):
  ( ($arr.bindings // {}) | to_entries )
  | [ .[]
      | .key as $k
      | .value as $b
      | select($b.frame != null)
      | ( (($b.contents // [])[0].window_id) // $b.window_id ) as $wid
      | select($wid != null)
      | { cell_key: $k,
          window_id: $wid,
          frame: $b.frame,
          ov:   ( G::frame_overlap_x($float_frame; $b.frame)
                * G::frame_overlap_y($float_frame; $b.frame) ),
          area: ( ($b.frame.w // 0) * ($b.frame.h // 0) ) } ]
  | map(select(.ov > 0))
  | if length == 0 then null
    else
      ( sort_by([ (- .ov), (- .area), (.frame.y // 0), (.frame.x // 0), .cell_key ]) | .[0] )
      | { cell_key, window_id, frame }
    end;
