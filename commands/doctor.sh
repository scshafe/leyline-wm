#!/usr/bin/env bash
# Native factual health and exclusive ownership; read-only, fail-closed.
_wm_doctor_resident_jobs_typed() {
  local jobs="$1"
  printf '%s' "$jobs" | jq -e '
    def integer: type == "number" and . == floor;
    def pid: . == null or (integer and . > 0);
    def fact:
      type == "object"
      and (keys | sort) == ["pid","registered"]
      and (.registered | type == "boolean")
      and (.pid | pid)
      and ((.registered == true) or (.pid == null));
    . as $jobs | ["leylined"] as $ids
    | (type == "object")
      and (($jobs | keys | sort) == $ids)
      and all($ids[]; . as $id | ($jobs | has($id)) and ($jobs[$id] | fact))
  ' >/dev/null 2>&1
}

# Validate the factual v1 health wire. Component aliases and unknown owners
# cannot substitute for the canonical `.health` schema.
_wm_doctor_resident_status_typed() {
  local core="$1"
  printf '%s' "$core" | jq -e '
    def integer: type == "number" and . == floor;
    def positive_integer: integer and . > 0;
    def nonnegative_integer: integer and . >= 0;
    def nullable_positive_integer: . == null or positive_integer;
    def nullable_nonnegative_integer: . == null or nonnegative_integer;
    def nullable_string: . == null or (type == "string" and length > 0);
    type == "object"
    and .ok == true
    and .op == "status"
    and (.pid | positive_integer)
    and (.revision | positive_integer)
    and (.health | type == "object")
    and (.health | keys | sort) == [
      "focus_observer","mode_subscription","owner","projection","resident",
      "schema","world_seed"
    ]
    and (.health.resident | type == "object")
    and (.world | type == "object")
    and (.world.management_enabled | type == "boolean")
    and (.world.resident_running | type == "boolean")
    and .health.schema == 2
    and .health.owner == "resident"
    and (.health.world_seed | type == "object")
    and (.health.world_seed | keys | sort) == ["ready","revision"]
    and (.health.world_seed.ready | type == "boolean")
    and (.health.world_seed.revision | nullable_nonnegative_integer)
    and (.health.focus_observer | type == "object")
    and (.health.focus_observer | keys | sort)
      == ["degraded_reason","generation","pid","ready","window_notifications_ready"]
    and (.health.focus_observer.ready | type == "boolean")
    and (.health.focus_observer.window_notifications_ready | type == "boolean")
    and (.health.focus_observer.pid | nullable_positive_integer)
    and (.health.focus_observer.generation | nullable_nonnegative_integer)
    and (.health.focus_observer.degraded_reason | nullable_string)
    and (.health.mode_subscription | type == "object")
    and (.health.mode_subscription | keys | sort)
      == ["connected","degraded_reason","epoch","ready","sequence"]
    and (.health.mode_subscription.connected | type == "boolean")
    and (.health.mode_subscription.ready | type == "boolean")
    and (.health.mode_subscription.epoch | nullable_string)
    and (.health.mode_subscription.sequence | nullable_nonnegative_integer)
    and (.health.mode_subscription.degraded_reason | nullable_string)
    and (.health.projection | type == "object")
    and (.health.projection | keys | sort)
      == ["degraded","degraded_reason","last_rendered_revision","mounted","required"]
    and ((.health.projection.required == null)
      or (.health.projection.required | type == "boolean"))
    and (.health.projection.mounted | type == "boolean")
    and (.health.projection.degraded | type == "boolean")
    and (.health.projection.degraded_reason | nullable_string)
    and (.health.projection.last_rendered_revision | nullable_nonnegative_integer)
  ' >/dev/null 2>&1
}

# One row per arm of wm_doctor_resident_verdicts; doctor_main refuses a shorter report.
wm_doctor_resident_verdict_rows=7
wm_doctor_resident_verdicts() {
  local jobs="$1" core="$2"
  if ! command -v jq >/dev/null 2>&1; then
    printf 'fail\tresident oracle requires jq; typed inputs cannot be validated\n'
    return 0
  fi
  if ! _wm_doctor_resident_jobs_typed "$jobs"; then
    printf 'fail\tresident jobs input malformed — require the typed leylined {registered,pid} fact (fail-closed)\n'
    return 0
  fi
  if ! _wm_doctor_resident_status_typed "$core"; then
    printf 'fail\tcore status malformed or unhealthy transport envelope — exact health schema 2 and resident owner required (fail-closed)\n'
    return 0
  fi

  local core_pid core_revision
  local leylined_registered leylined_pid
  core_pid="$(printf '%s' "$core" | jq -r '.pid')"
  core_revision="$(printf '%s' "$core" | jq -r '.revision')"
  leylined_registered="$(printf '%s' "$jobs" | jq -r '.leylined.registered')"
  leylined_pid="$(printf '%s' "$jobs" | jq -r '.leylined.pid // "null"')"

  if [[ "$leylined_registered" == true && "$leylined_pid" != null \
      && "$leylined_pid" == "$core_pid" ]]; then
    printf 'ok\tresident core: registered launchd pid %s exactly matches core status\n' "$core_pid"
  else
    printf 'fail\tresident core identity mismatch: registered=%s launchd_pid=%s core_pid=%s — zero/stale owner (fail-closed)\n' \
      "$leylined_registered" "$leylined_pid" "$core_pid"
  fi

  printf 'ok\tresident owns management capabilities under health schema 2\n'

  local globally_off=false world_complete
  world_complete="$(printf '%s' "$core" | jq -r '
    if .world.observation.world_complete == true then "true" else "false" end')"
  if printf '%s' "$core" | jq -e '
      .world.management_enabled == false and .world.resident_running == false
    ' >/dev/null 2>&1; then
    globally_off=true
    printf 'ok\tglobal OFF: resident controls remain available; management readiness is intentionally inactive\n'
  elif [[ "$world_complete" == true ]] && printf '%s' "$core" | jq -e '
      .world.management_enabled == true and .world.resident_running == true
    ' >/dev/null 2>&1; then
    printf 'ok\tworld observation: positively complete (source authority verified)\n'
  else
    printf 'fail\tworld observation incomplete or missing — source completeness is required before management can be healthy\n'
  fi

  local seed_ready seed_revision
  seed_ready="$(printf '%s' "$core" | jq -r '.health.world_seed.ready')"
  seed_revision="$(printf '%s' "$core" | jq -r '.health.world_seed.revision // "null"')"
  if $globally_off; then
    printf 'ok\tworld seed: inactive during global OFF (readiness not claimed)\n'
  elif [[ "$seed_ready" == true && "$seed_revision" != null ]] \
      && (( seed_revision >= 1 )); then
    printf 'ok\tworld seed: ready at revision %s\n' "$seed_revision"
  else
    printf 'fail\tworld seed not ready: ready=%s revision=%s (need ready=true, revision>=1)\n' \
      "$seed_ready" "$seed_revision"
  fi

  local focus_ready focus_window_ready focus_pid focus_generation focus_reason
  focus_ready="$(printf '%s' "$core" | jq -r '.health.focus_observer.ready')"
  focus_window_ready="$(printf '%s' "$core" | jq -r '.health.focus_observer.window_notifications_ready')"
  focus_pid="$(printf '%s' "$core" | jq -r '.health.focus_observer.pid // "null"')"
  focus_generation="$(printf '%s' "$core" | jq -r '.health.focus_observer.generation')"
  focus_reason="$(printf '%s' "$core" | jq -r '.health.focus_observer.degraded_reason // ""')"
  if $globally_off; then
    if [[ "$focus_ready" == false && "$focus_window_ready" == false ]]; then
      printf 'ok\tfocus observer: intentionally detached during global OFF\n'
    else
      printf 'fail\tfocus observer still active during global OFF: ready=%s window_ready=%s\n' "$focus_ready" "$focus_window_ready"
    fi
  elif [[ "$focus_ready" == true && "$focus_generation" != null ]] \
      && (( focus_generation >= 1 )); then
    if [[ "$focus_window_ready" == true ]]; then
      printf 'ok\tfocus observer: ready (pid=%s generation=%s; window notifications attached)\n' \
        "$focus_pid" "$focus_generation"
    else
      printf 'ok\tfocus observer: ready (pid=%s generation=%s; no focused-window notification target — valid context)\n' \
        "$focus_pid" "$focus_generation"
    fi
  else
    printf 'fail\tfocus observer not ready: ready=%s generation=%s reason=%s\n' \
      "$focus_ready" "$focus_generation" "${focus_reason:-none}"
  fi

  if ! printf '%s' "$core" | jq -e '
      .health.resident as $resident | $resident.input as $input
      | ($resident.mode_source == "in_process")
        and ($input | type == "object")
        and all(["tap_installed","desired_running","claims_allowed","space_control_allowed","accepting_claims","tap_create_failed","safety_released"][];
          . as $key | ($input[$key] | type == "boolean"))
        and ($input.mode | IN("default","move","resize"))
        and ($input.generation | type == "number" and . >= 0 and . == floor)
        and ($input.active_action_ids | type == "array")
        and ($input.active_action_ids | all(.[]; type == "string" and length > 0))
    ' >/dev/null 2>&1; then
    printf 'fail\tnative input facts missing/malformed — require in-process mode source and tap/claim facts\n'
  elif $globally_off; then
    if printf '%s' "$core" | jq -e '
        .health.resident.input as $input
        | $input.desired_running == false and $input.tap_installed == false
          and $input.claims_allowed == false and $input.space_control_allowed == false and $input.accepting_claims == false
          and $input.mode == "default" and $input.active_action_ids == []
      ' >/dev/null 2>&1; then
      printf 'ok\tnative input: global OFF releases the tap and all mode claims (controls remain resident)\n'
    else
      printf 'fail\tnative input still claims or retains a tap/modal state during global OFF\n'
    fi
  elif printf '%s' "$core" | jq -e '
      .health.resident.input as $input | .world.focus as $focus
      | $input.desired_running == true and $input.tap_installed == true
        and $input.tap_create_failed == false and $input.safety_released == false
        and (if $focus.eligible == true and $focus.space_enabled == true and $focus.space_visible == true
          then $input.claims_allowed == true and $input.accepting_claims == true
          else $input.claims_allowed == false and $input.mode == "default"
            and (if $input.space_control_allowed == true then
              $input.accepting_claims == true and $input.active_action_ids == ["space.management.toggle"]
              else $input.accepting_claims == false and $input.active_action_ids == [] end)
          end)
    ' >/dev/null 2>&1; then
    printf 'ok\tnative input: in-process mode/tap ready; claims match focused Space eligibility\n'
  else
    printf 'fail\tnative input unavailable or claim policy contradicts the observed focused Space\n'
  fi

  local projection_required projection_mounted
  local projection_degraded projection_reason projection_revision
  projection_required="$(printf '%s' "$core" | jq -r '
    if .health.projection.required == null then "null"
    else (.health.projection.required | tostring) end')"
  projection_mounted="$(printf '%s' "$core" | jq -r '.health.projection.mounted')"
  projection_degraded="$(printf '%s' "$core" | jq -r '.health.projection.degraded')"
  projection_reason="$(printf '%s' "$core" | jq -r '.health.projection.degraded_reason // ""')"
  projection_revision="$(printf '%s' "$core" | jq -r '.health.projection.last_rendered_revision // "null"')"
    if $globally_off; then
      if [[ "$projection_mounted" == false && "$projection_revision" == null && "$projection_degraded" == false ]]; then
        printf 'ok\tleylined border projection: intentionally unmounted during global OFF\n'
      else
        printf 'fail\tleylined border projection not released during global OFF: mounted=%s last_rendered=%s degraded=%s\n' \
          "$projection_mounted" "$projection_revision" "$projection_degraded"
      fi
    elif [[ "$projection_required" == true && "$projection_mounted" == true \
        && "$projection_degraded" == false && "$projection_revision" == "$core_revision" ]]; then
      printf 'ok\tleylined border projection: required, mounted, non-degraded, rendered revision %s\n' \
        "$core_revision"
    else
      printf 'fail\tleylined border projection unhealthy: required=%s mounted=%s degraded=%s last_rendered=%s core_revision=%s reason=%s\n' \
        "$projection_required" "$projection_mounted" "$projection_degraded" \
        "$projection_revision" "$core_revision" "${projection_reason:-none}"
    fi

}

_wm_doctor_resident_launchd_fact() {
  local label="$1" out state pid="" launch_rc=0
  out="$(/bin/launchctl print "gui/${UID}/${label}" 2>&1)" || launch_rc=$?
  if (( launch_rc == 0 )); then
    [[ -n "$out" ]] || return 1
    [[ "${out%%$'\n'*}" == "gui/${UID}/${label} = {" ]] || return 1
    state="$(printf '%s\n' "$out" | awk -F '[[:space:]]*=[[:space:]]*' '
      /^[[:space:]]*state[[:space:]]*=/ { print $2; exit }
    ')"
    [[ -n "$state" ]] || return 1
    pid="$(printf '%s\n' "$out" | awk -F '[[:space:]]*=[[:space:]]*' '
      /^[[:space:]]*pid[[:space:]]*=/ { print $2; exit }
    ')"
    if [[ -n "$pid" && ! "$pid" =~ ^[1-9][0-9]*$ ]]; then return 1; fi
    if [[ "$state" == running && -z "$pid" ]]; then return 1; fi
    if [[ "$state" != running && -n "$pid" ]]; then return 1; fi
    if [[ -n "$pid" ]]; then
      jq -cn --argjson pid "$pid" '{registered:true,pid:$pid}'
    else
      jq -cn '{registered:true,pid:null}'
    fi
  elif [[ "$launch_rc" == 113 && "$out" == *"Could not find service \"$label\""* \
      && "$out" == *"domain for user gui: ${UID}"* ]]; then
    jq -cn '{registered:false,pid:null}'
  else
    return 1
  fi
}

_wm_doctor_collect_jobs_json() {
  if [[ -n "${LEYLINE_DOCTOR_JOBS_FILE:-}" ]]; then cat "$LEYLINE_DOCTOR_JOBS_FILE"; return $?; fi
  local leylined
  leylined="$(_wm_doctor_resident_launchd_fact org.leyline.leylined)" || return 1
  jq -cn --argjson leylined "$leylined" '{leylined:$leylined}'
}

doctor_main() {
  case "${1:-}" in '') ;; --help|-h) printf '%s\n' 'ley doctor'; return 0 ;; *) wm_err 'usage: ley doctor'; return 64 ;; esac
  command -v jq >/dev/null 2>&1 || { wm_err 'doctor requires jq for typed diagnostics'; return 69; }
  local jobs core envelope rows level message errors=0 count=0
  wm_resident_client 'resident client unavailable; native health unverified' || return $?
  jobs="$(_wm_doctor_collect_jobs_json)" || { wm_err 'launchd facts unavailable; native ownership unverified'; return 65; }
  envelope="$("$LEYLINE_RESIDENT_CLIENT_BIN" status)" || { wm_err 'resident health client failed'; return 65; }
  core="$(printf '%s' "$envelope" | jq -ec 'select(.error==null) | .data | select(type=="object")')" || { wm_err 'resident status envelope malformed'; return 65; }
  rows="$(wm_doctor_resident_verdicts "$jobs" "$core")" || return 65
  while IFS=$'\t' read -r level message; do
    [[ -n "$level" && -n "$message" ]] || { errors=$((errors+1)); continue; }
    count=$((count+1))
    case "$level" in ok) wm_ok "$message" ;; warn) wm_warn "$message" ;; fail) wm_err "$message"; errors=$((errors+1)) ;; *) errors=$((errors+1)) ;; esac
  done <<< "$rows"
  [[ "$count" -ge "$wm_doctor_resident_verdict_rows" ]] || errors=$((errors+1))
  if (( errors>0 )); then wm_err "$errors resident diagnostic checks failed"; return 1; fi
  wm_ok 'resident diagnostics passed'
}
