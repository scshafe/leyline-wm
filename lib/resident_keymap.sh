#!/usr/bin/env bash
# @canonical retained_claim_validator -- shipping routes and native claims match the v1 contract.
wm_keymap_tap_disjoint_claims() {
  local issues='[]' source_root="$LEYLINE_HOME"
  local oracle="${LEYLINE_RESIDENT_CLAIM_ORACLE:-$source_root/config/input-routes.json}"
  if [[ ! -e "$oracle" && -z "${LEYLINE_RESIDENT_CLAIM_ORACLE:-}" ]]; then
    oracle="$source_root/leylined/Fixtures/input/v1-claims.json"
  fi
  local binary="${LEYLINE_RESIDENT_CLIENT_BIN:-$LEYLINE_HOME/bin/leylined}"
  local native_home="${LEYLINE_KEYMAP_HOME:-$LEYLINE_HOME}"
  local manifest="${LEYLINE_KEYMAP_MANIFEST:-$native_home/keymap/global.json}"
  local modes="${LEYLINE_KEYMAP_MODES:-$native_home/keymap/modes.json}"
  _rkc_issue() {
    issues="$(printf '%s' "$issues" | jq -c --arg l "$1" --arg c "$2" --arg md "$3" --arg m "$4" \
      '. + [{level:$l,code:$c,mode:$md,family:"keymap",owner:"keymap/modes.json",reload:"ley ctl restart",path:"",message:$m}]')"
  }
  # Pin independent current-route evidence, rather than blessing a candidate dump.
  local digest="" expected_digest=257b488e2402932c1e1665455caa9105b640c97dc0876e4e8c530678f493b6c5
  if [[ -r "$oracle" ]] && jq -e '.schema=="leyline/v1-input-routes"' "$oracle" >/dev/null 2>&1 && command -v shasum >/dev/null 2>&1; then
    digest="$(jq -Sc . "$oracle" | shasum -a 256 | awk '{print $1}')"
  fi
  if [[ "$digest" != "$expected_digest" ]]; then
    _rkc_issue error resident_claims_oracle_invalid "" "v1 route contract is missing, unreadable or changed"
    printf '%s' "$issues"; return 0
  fi
  if [[ ! -x "$binary" ]]; then
    _rkc_issue error resident_claims_binary_unavailable "" "native claim owner unavailable: $binary"
    printf '%s' "$issues"; return 0
  fi
  local source_routes
  if ! source_routes="$(jq -cn --slurpfile g "$manifest" --slurpfile m "$modes" --slurpfile f "$oracle" '
    if ($g|length)!=1 or ($m|length)!=1 or ($g[0].bindings|type)!="array"
      or ($m[0].modes|type)!="array" or $m[0]._schema!="modes/v1"
      or ($g[0].bindings|length)==0 or ($m[0].modes|length)==0
      then error("empty or malformed source") else . end |
    if ($m[0].modes|map(.id)|sort) != ["move","resize"]
      or ($g[0].bindings|map(.chord)|unique|length) != ($g[0].bindings|length)
      or ($g[0].reserved // []) != $f[0].reserved_chords
      then error("unknown modes or repeated/reserved chords") else . end |
    $f[0].retained_action_ids as $retained |
    def kept($id): ($id|type)=="string" and ($retained|index($id))!=null;
    if all($g[0].bindings[]; (.chord|type)=="string" and kept(.action_id))
      and all($m[0].modes[];
        kept(.enter.action_id) and (.enter.chord|type)=="string"
        and (.bindings|type)=="array" and (.bindings|length)>0
        and (.exit_keys|type)=="array" and all(.exit_keys[];type=="string")
        and ((.bindings|map(.key)|unique|length)==(.bindings|length))
        and all(.bindings[];(.key|type)=="string" and kept(.action_id)))
      then . else error("unsupported source routes") end |
    ($g[0].bindings|map({key:.chord,value:.action_id})|from_entries) as $globals |
    def modal($name):
      ($m[0].modes|map(select(.id==$name))|first) as $mode |
      (reduce $mode.bindings[] as $b ($globals;.[$b.key]=$b.action_id)) +
      ($mode.exit_keys|map({key:.,value:"mode.cancel"})|from_entries);
    {default:($globals + ($m[0].modes|map({key:.enter.chord,value:.enter.action_id})|from_entries)),
      move:modal("move"),resize:modal("resize")}
  ' 2>/dev/null)"; then
    _rkc_issue error resident_claims_source_invalid "" "v1 keymap source is empty, missing, malformed or declares unsupported routes"
    printf '%s' "$issues"; return 0
  fi
  if ! jq -en --argjson actual "$source_routes" --slurpfile f "$oracle" '$actual==$f[0].expected_action_routes' >/dev/null 2>&1; then
    _rkc_issue error resident_claims_source_mismatch "" "configured source routes differ from the independent v1 contract"
  fi
  local mode dump lines want checked=0 claim_total=0
  while IFS= read -r mode; do
    [[ -n "$mode" ]] || continue
    if ! dump="$("$binary" --dump-claims "$mode" --json --home "$native_home" 2>/dev/null)"; then
      _rkc_issue error resident_claims_dump_failed "$mode" "native claim dump refused configuration or mode"
      continue
    fi
    checked=$((checked+1))
    if ! printf '%s' "$dump" | jq -e --arg md "$mode" '
      .schema=="leyline/resident-input-claims/v1" and .mode==$md and (.claims|type)=="array"
      and (.action_routes|type)=="object" and .claim_count==(.claims|length)
      and .claims==(.action_routes|keys) and (.retained_action_ids|length)==25
    ' >/dev/null 2>&1; then
      _rkc_issue error resident_claims_dump_invalid "$mode" "claim dump shape/count/sorted chord-to-action proof invalid"
      continue
    fi
    if ! printf '%s' "$dump" | jq -e --slurpfile f "$oracle" '
      (.retained_action_ids|sort)==($f[0].retained_action_ids|sort)
      and .unsupported_action_ids==$f[0].unsupported_action_ids
    ' >/dev/null 2>&1; then
      _rkc_issue error resident_claims_disposition_mismatch "$mode" "native supported-action inventory differs from the v1 contract"
    fi
    want="$(jq -c --arg md "$mode" '.expected_action_routes[$md]' "$oracle")"
    if ! printf '%s' "$dump" | jq -e --argjson want "$want" '.action_routes==$want and .claims==($want|keys)' >/dev/null 2>&1; then
      _rkc_issue error resident_claims_route_mismatch "$mode" "actual chord-to-action routes differ from the v1 contract"
    fi
    if ! lines="$("$binary" --dump-claims "$mode" --home "$native_home" 2>/dev/null)"; then
      _rkc_issue error resident_claims_dump_failed "$mode" "sorted line claim dump failed"
      continue
    fi
    if ! printf '%s\n' "$lines" | jq -Rsc --argjson want "$want" \
      '(split("\n")|map(select(length>0)))==($want|keys)' | jq -e . >/dev/null 2>&1; then
      _rkc_issue error resident_claims_line_mismatch "$mode" "line claim inventory differs from the independent v1 contract"
    fi
    claim_total=$((claim_total+$(printf '%s' "$dump" | jq '.claim_count')))
  done < <(jq -r '.expected_action_routes|keys[]' "$oracle")
  if [[ "$checked" -ne 3 || "$claim_total" -ne 43 ]]; then
    _rkc_issue error tap_coverage_vacuous "" "v1 claim coverage must check three modes and exactly forty-three claims"
  fi
  _rkc_issue info resident_claims_audit "" "native owner: $checked mode inventories, $claim_total claims and 25 supported actions checked against v1"
  printf '%s' "$issues"
}
