# focusrole.jq — the focused-window BORDER-ROLE resolver (movement-mode A1).
#
# One pure question: given the stored layout, the focused window_id, and the
# observed set (the caps source), which role should the focus ring wear?
#
#   bound, alone in its cell                        -> "focus"    (focused tiled)
#   bound, cell stacks more than one window         -> "stacked"  (the "windows behind" cue)
#   bound but OFF-TOP (behind a stack's presented)  -> "stacked"
#   unbound + STANDARD + RESIZABLE (a real float)   -> "floating" (azure)
#   unbound + non-standard / non-resizable (dialog) -> "error"    (the honest no-match: nothing
#       is tiled and it is not a real float either — NOT false focus-green)
#   no/invalid focus, caps unavailable              -> "error"    (can't prove tiled → don't claim it)
#
# Shape-aware: the live store is the line-primary arrangement ({segments,
# bindings, off_top}; no .root_id) — resolved against .bindings/.off_top. The
# tree branch keeps the pre-port .nodes/.root_id resolution verbatim so
# tree-injecting tests and tree-seeded stores stay correct. This module reads
# bindings/off_top STRUCTURALLY (no arrangement import — the read-only-lens
# guard in parcel/tests.sh stays clean by construction).
#
# Consumers: lib/parcel/store.sh wm_parcel_apply_focus_border (nav + the
# reactor's post-settle recolor). Fixtures: parcel/fixtures/focusrole/.

import "parcel" as P;
import "autotile" as A;

def border_role($store; $w; $obs):
  def caps_role:
    (($obs // []) | map(select(.window_id == $w)) | .[0]) as $fw
    | if ($fw != null) and (A::is_standard($fw)) and (A::is_resizable($fw))
      then "floating" else "error" end;
  if ($store.segments != null) and ($store.root_id == null) then
    # Arrangement: the binding whose contents (or bare window_id) carries $w.
    ( [ ($store.bindings // {})[]
        | select((((.contents // []) | map(.window_id)) + [.window_id]) | index($w) != null)
      ][0] // null ) as $bind
    | if $bind != null then
        (if ((($bind.contents // []) | length) > 1) then "stacked" else "focus" end)
      elif ([ ($store.off_top // [])[] | select(.window_id == $w) ] | length) > 0
      then "stacked"
      else caps_role end
  else
    # Tree store (legacy shape): leaf lookup + stack-ancestor walk, verbatim
    # from the pre-A1 inline resolver.
    ($store.nodes // {}) as $n | ($store.root_id) as $r
    | ([ $n | to_entries[] | select(.value.window_id == $w) | .key ][0] // null) as $leaf
    | if $leaf != null then
        (if ([ P::paths_to($n; $r; $leaf)[]? | .[0:-1][]
               | select(($n[.].mode // "region") == "stack") ] | length) > 0
         then "stacked" else "focus" end)
      else caps_role end
  end;
