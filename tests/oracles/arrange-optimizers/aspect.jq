# Parcel — arrange-auto ASPECT-RATIO optimizer (Wave 2, fork 3, v1).
#
# PURE module — ZERO read-only-lens imports. The harness guard scans every *.jq
# for `^import "(floorplan|arrangement)"`; this module must never import one.
# The aspect math needs no geometry lens: a cell's aspect distortion in an
# equal-height justified-rows layout collapses to |log(R / c_r)| (R = #rows,
# c_r = #cells in that cell's row), INDEPENDENT of the display aspect ratio
# (cell_AR = (W/c_r)/(H/R), display_AR = W/H, ratio = R/c_r). The column-major
# transpose with C columns scores |log(c_c / C)| (c_c = #cells in column c). A
# layout's score is the MINIMAX = max distortion over its bands.
#
# choose($w; $display_frame; $config) -> {orient, parts, rows, cols, score}
#   $w            : window count (integer; <1 -> empty no-op partition).
#   $display_frame: {x,y,w,h} — UNUSED by v1 (the score is display-AR-blind; kept
#                   in the signature so an AR-aware optimizer is a drop-in).
#   $config       : reserved (v1 reads no knobs).
# Returns the chosen NO-HOLE partition: orient in {"rows","cols"}; parts = the
# per-band cell counts (sum == $w); rows/cols = the grid's divisions (tie-break +
# legibility); score = the (rounded) minimax aspect distortion.
#
# Candidate family (a STRICT SUBSET of all no-hole tilings — "optimal within the
# justified-rows + transpose family", NOT globally optimal): row-major R=1..W and
# column-major C=1..W, each with the balanced ceil/floor split of W across its
# bands. Tie-break (AR-blind, DETERMINISTIC): [score asc, rows asc, row-major
# before col, cols asc] — "fewer rows first" prefers the flatter/wider layout
# (the intuitive landscape default: W=2 -> side-by-side, not stacked).

def _abs: if . < 0 then -. else . end;

# Round a NON-NEGATIVE value to 6 dp (floor-based, so it needs no `round`
# builtin). Scores are |log(...)| >= 0, so this is exact-tie-stable: log(0.5)
# and log(2) both round to 0.693147, making a genuine tie compare equal rather
# than diverging by a sub-ULP float wobble.
def _round6: (. * 1000000 + 0.5 | floor) / 1000000;

# Balanced split of $n items into $k bands: the first ($n mod $k) bands get
# ceil($n/$k), the rest get floor($n/$k). Every band >= 1 when $n >= $k.
def _split($n; $k):
  ($n / $k | floor) as $base
  | ($n - ($base * $k)) as $rem
  | [ range(0; $k) | if . < $rem then ($base + 1) else $base end ];

def choose($w; $display_frame; $config):
  if ($w | type) != "number" or $w < 1 then
    { orient: "rows", parts: [], rows: 0, cols: 0, score: 0 }
  elif $w == 1 then
    { orient: "rows", parts: [1], rows: 1, cols: 1, score: 0 }
  else
    ( [ range(1; $w + 1) as $k
        | _split($w; $k) as $p
        # row-major: $k rows; band b has $p[b] cells -> distortion |log($k/$p[b])|.
        | { orient: "rows", parts: $p,
            score: ([ $p[] | (($k / .) | log | _abs) ] | max | _round6) } ]
      + [ range(1; $w + 1) as $k
        | _split($w; $k) as $p
        # col-major: $k cols; band c has $p[c] cells -> distortion |log($p[c]/$k)|.
        | { orient: "cols", parts: $p,
            score: ([ $p[] | ((. / $k) | log | _abs) ] | max | _round6) } ] ) as $cands
    | ( $cands
        | map( . + { rows: (if .orient == "rows" then (.parts | length) else (.parts | max) end),
                     cols: (if .orient == "rows" then (.parts | max) else (.parts | length) end),
                     ord:  (if .orient == "rows" then 0 else 1 end) } )
        | sort_by([ .score, .rows, .ord, .cols ])
        | .[0] )
    | { orient, parts, rows, cols, score }
  end;
