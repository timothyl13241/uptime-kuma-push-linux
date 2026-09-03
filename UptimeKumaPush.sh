#!/usr/bin/env bash
set -uo pipefail

#==============================================================================
# UptimeKumaPush.sh
# Bash conversion of UptimeKumaPush.ps1
#==============================================================================

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script_name="$(basename "${BASH_SOURCE[0]}")"
base_name="${script_name%.*}"
config_file="${script_dir}/${base_name}.json"

urlencode() {
  local raw="$1"
  local length="${#raw}"
  local encoded=""
  local i c

  for ((i = 0; i < length; i++)); do
    c="${raw:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) encoded+="$c" ;;
      ' ') encoded+="%20" ;;
      *) printf -v encoded '%s%%%02X' "$encoded" "'${c}" ;;
    esac
  done

  printf '%s' "$encoded"
}

require_command() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required dependency: $command_name" >&2
    return 1
  fi
}

normalize_host() {
  local host="$1"
  if [[ "$host" != http://* && "$host" != https://* ]]; then
    printf 'https://%s' "$host"
  else
    printf '%s' "$host"
  fi
}

get_timeout_ms() {
  local monitor_json="$1"
  local default_timeout="$2"
  local timeout
  timeout="$(jq -r '.timeout // empty' <<<"$monitor_json")"

  if [[ "$timeout" =~ ^[0-9]+$ ]]; then
    printf '%s' "$timeout"
  else
    printf '%s' "$default_timeout"
  fi
}

get_timeout_seconds() {
  local monitor_json="$1"
  local default_timeout="$2"
  local timeout
  timeout="$(jq -r '.timeout // empty' <<<"$monitor_json")"

  if [[ "$timeout" =~ ^[0-9]+$ ]]; then
    printf '%s' "$timeout"
  else
    printf '%s' "$default_timeout"
  fi
}

test_port() {
  local monitor_json="$1"
  local host port timeout_ms timeout_seconds

  host="$(jq -r '.host // empty' <<<"$monitor_json")"
  port="$(jq -r '.port // empty' <<<"$monitor_json")"
  timeout_ms="$(get_timeout_ms "$monitor_json" 2000)"
  timeout_seconds=$(( (timeout_ms + 999) / 1000 ))
  (( timeout_seconds < 1 )) && timeout_seconds=1

  [[ -n "$host" && "$port" =~ ^[0-9]+$ ]] || return 1

  timeout "$timeout_seconds" bash -c "</dev/tcp/${host}/${port}" >/dev/null 2>&1
}

test_ping() {
  local monitor_json="$1"
  local host timeout_ms timeout_seconds ping_output response_time

  host="$(jq -r '.host // empty' <<<"$monitor_json")"
  timeout_ms="$(get_timeout_ms "$monitor_json" 2000)"
  timeout_seconds=$(( (timeout_ms + 999) / 1000 ))
  (( timeout_seconds < 1 )) && timeout_seconds=1

  [[ -n "$host" ]] || return 1

  ping_output="$(ping -c 1 -W "$timeout_seconds" "$host" 2>/dev/null || true)"
  if [[ -n "$ping_output" ]]; then
    response_time="$(sed -nE 's/.*time=([0-9]+(\.[0-9]+)?).*/\1/p' <<<"$ping_output" | head -n1)"
    if [[ -z "$response_time" ]]; then
      response_time=1
    else
      response_time="${response_time%.*}"
      [[ -z "$response_time" ]] && response_time=1
    fi
    printf '%s' "$response_time"
    return 0
  fi

  return 1
}

test_website() {
  local monitor_json="$1"
  local host search timeout_seconds response_file status_code

  search="$(jq -r '.search // empty' <<<"$monitor_json")"
  host="$(normalize_host "$(jq -r '.host // empty' <<<"$monitor_json")")"
  timeout_seconds="$(get_timeout_seconds "$monitor_json" 4)"

  [[ -n "$host" ]] || return 1

  response_file="$(mktemp)"
  status_code="$(curl -ksS -L --max-time "$timeout_seconds" -o "$response_file" -w '%{http_code}' "$host" 2>/dev/null || echo 000)"

  if [[ "$status_code" == "000" ]]; then
    rm -f "$response_file"
    return 1
  fi

  if [[ -n "$search" ]]; then
    if ! grep -Fq "$search" "$response_file"; then
      rm -f "$response_file"
      return 1
    fi
  fi

  rm -f "$response_file"
  return 0
}

test_host() {
  local monitor_json="$1"
  local monitor_type monitor_host result=1 ping_value=0

  monitor_type="$(jq -r '.type // empty' <<<"$monitor_json")"
  monitor_host="$(jq -r '.host // empty' <<<"$monitor_json")"

  case "$monitor_type" in
    ping)
      if ping_value="$(test_ping "$monitor_json")"; then
        result=0
      fi
      ;;
    website)
      if test_website "$monitor_json"; then
        result=0
      fi
      ;;
    port)
      if test_port "$monitor_json"; then
        result=0
      fi
      ;;
    *)
      result=1
      ;;
  esac

  if (( result == 0 )); then
    echo "Up:   $(jq -c '.' <<<"$monitor_json")" >&2
  else
    echo "Down: $(jq -c '.' <<<"$monitor_json")" >&2
  fi

  printf '%s|%s|%s:%s\n' "$result" "$ping_value" "$monitor_type" "$monitor_host"
}

require_command jq || exit 1
require_command curl || exit 1

while true; do
  if [[ ! -f "$config_file" ]]; then
    echo "Config issue: missing $config_file" >&2
    sleep 2
    continue
  fi

  if ! jq -e '.' "$config_file" >/dev/null 2>&1; then
    echo "Config issue: invalid JSON in $config_file" >&2
    sleep 2
    continue
  fi

  if jq -e '.monitors[]? | select((.type // "") == "ping" or any((.group // [])[]?; (.type // "") == "ping"))' "$config_file" >/dev/null 2>&1; then
    require_command ping || exit 1
  fi

  if jq -e '.monitors[]? | select((.type // "") == "port" or any((.group // [])[]?; (.type // "") == "port"))' "$config_file" >/dev/null 2>&1; then
    require_command timeout || exit 1
  fi

  monitors_count="$(jq '.monitors | length' "$config_file" 2>/dev/null || echo 0)"
  echo "Total monitors: ${monitors_count}"

  push_url="$(jq -r '.settings.push_url // empty' "$config_file")"
  push_if_down="$(jq -r 'if .settings | has("push_if_down") then .settings.push_if_down else true end' "$config_file")"
  loop_enabled="$(jq -r 'if .settings | has("loop") then .settings.loop else true end' "$config_file")"
  loop_delay="$(jq -r '.settings.loop_delay // 60' "$config_file")"

  if [[ -z "$push_url" ]]; then
    echo "Config issue: settings.push_url is required" >&2
    sleep 2
    continue
  fi

  if ! [[ "$loop_delay" =~ ^[0-9]+$ ]]; then
    echo "Config issue: settings.loop_delay must be a non-negative integer" >&2
    sleep 2
    continue
  fi

  while IFS= read -r monitor; do
    [[ -n "$monitor" ]] || continue

    message=""
    ping=0
    result=1
    monitor_id_val="$(jq -r '.id // empty' <<<"$monitor")"

    if jq -e '.group? and (.group | length > 0)' >/dev/null <<<"$monitor"; then
      result=0
      down_message=""
      up_message=""
      group_count="$(jq '.group | length' <<<"$monitor")"
      echo "Group Monitor: id=${monitor_id_val} count=${group_count}"

      while IFS= read -r groupmonitor; do
        [[ -n "$groupmonitor" ]] || continue

        host_result="$(test_host "$groupmonitor")"
        member_result="${host_result%%|*}"
        member_message="${host_result#*|}"
        member_message="${member_message#*|}"

        if [[ "$member_result" == "0" ]]; then
          up_message+="${member_message}  "
        else
          result=1
          down_message+="${member_message}  "
        fi
      done < <(jq -c '.group[]' <<<"$monitor")

      [[ -n "$down_message" ]] && down_message="Down: ${down_message}"
      [[ -n "$up_message" ]] && up_message="Up: ${up_message}"
      message="${down_message}${up_message}"
    else
      host_result="$(test_host "$monitor")"
      result="${host_result%%|*}"
      ping_part="${host_result#*|}"
      ping="${ping_part%%|*}"
      message="${host_result#*|}"
      message="${message#*|}"
    fi

    if [[ "$result" == "1" && "$push_if_down" == "false" ]]; then
      continue
    fi

    if [[ "$result" == "0" ]]; then
      status="up"
    else
      status="down"
    fi

    message_encoded="$(urlencode "$message")"
    push_url_updated="${push_url//\{ID\}/$monitor_id_val}"
    push_url_updated="${push_url_updated//\{STATUS\}/$status}"
    push_url_updated="${push_url_updated//\{MSG\}/$message_encoded}"
    push_url_updated="${push_url_updated//\{PING\}/$ping}"

    if webrequest="$(curl -ksS "$push_url_updated" 2>&1)"; then
      echo "Push Response: $webrequest"
    else
      echo "Push Error: $webrequest"
    fi
  done < <(jq -c '.monitors[]?' "$config_file")

  if [[ "$loop_enabled" == "false" ]]; then
    exit 0
  fi

  echo "Sleeping for ${loop_delay} seconds"
  sleep "$loop_delay"
done
