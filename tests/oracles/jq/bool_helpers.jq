# Boolean / field-presence helpers for jq filters that consume window /
# space JSON. Some sources use hyphenated field names ("is-visible",
# "is-minimized", "has-focus") that downstream snapshots normalize to
# underscored forms. This module picks the first present spelling, falling
# back to a caller-supplied default when neither key is set.
#
# Lives in lib/jq/ so both shell-embedded jq blocks (commands/*.sh)
# and standalone jq filters (lib/jq/*.jq) can
# import it via `-L "$LEYLINE_LIB_DIR/jq"; import "bool_helpers" as B;`.

def bool_field($o; $primary; $fallback; $default):
  if $o | has($primary) then $o[$primary]
  elif $o | has($fallback) then $o[$fallback]
  else $default end;
