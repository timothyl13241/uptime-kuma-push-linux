#!/usr/bin/env bash
set -u

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

json_get() {
  local filter="$1"
  jq -r "$filter // empty" "$config_file" 2>/dev/null
}

json_bool() {
  local filter="$1"
  local value
  value="$(jq -r "$filter // empty" "$config_file" 2>/dev/null)" || return 1
  [[ "$value" == "true" ]]
}

get_timeout() {
  local monitor_json="$1"
  local default_timeout="$2"
  local timeout
  timeout="$(jq -r '.timeout // empty' <<<"$monitor_json")"
  if [[ -n "$timeout" ]]; then
    printf '%s' "$timeout"
  else
    printf '%s' "$default_timeout"
  fi
}

get_search() {
  local monitor_json="$1"
  jq -r '.search // empty' <<<"$monitor_json"
}

monitor_host() {
  jq -r '.host // empty' <<<"$1"
}

monitor_type() {
  jq -r '.type // empty' <<<"$1"
}

monitor_id() {
  jq -r '.id // empty' <<<"$1"
}

normalize_host() {
  local host="$1"
  if [[ "$host" != http://* && "$host" != https://* ]]; then
    printf 'https://%s' "$host"
  else
    printf '%s' "$host"
  fi
}

curl_status_code() {
  local url="$1"
  local timeout="$2"
  local response
  response="$(curl -ksS -o /dev/null -w '%{http_code}' --max-time "$timeout" "$url" 2>/dev/null || true)"
  [[ "$response" =~ ^[0-9]+$ ]] && [[ "$response" != "000" ]]
}

Test_Port() {
  local monitor_json="$1"
  local host port timeout
  host="$(monitor_host "$monitor_json")"
  port="$(jq -r '.port // empty' <<<"$monitor_json")"
  timeout="$(get_timeout "$monitor_json" 2000)"
  timeout=$(( (timeout + 999) / 1000 ))
  timeout=${timeout:-2}

  if command -v timeout >/dev/null 2>&1; then
    timeout "$timeout" bash -lc "</dev/tcp/${host}/${port}" >/dev/null 2>&1
  else
    python3 - <<'PY' "$host" "$port" "$timeout"
import socket, sys
host, port, timeout = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
s = socket.socket()
s.settimeout(timeout)
try:
    s.connect((host, port))
    sys.exit(0)
except Exception:
    sys.exit(1)
finally:
    s.close()
PY
  fi
}

Test_Ping() {
  local monitor_json="$1"
  local host timeout
  host="$(monitor_host "$monitor_json")"
  timeout="$(get_timeout "$monitor_json" 2000)"

  if command -v ping >/dev/null 2>&1; then
    if ping -c 1 -W $(( (timeout + 999) / 1000 )) "$host" >/dev/null 2>&1; then
      printf '1'
      return 0
    fi
  fi
  return 1
}

Test_Website() {
  local monitor_json="$1"
  local host search timeout content
  search="$(get_search "$monitor_json")"
  host="$(normalize_host "$(monitor_host "$monitor_json")")"
  timeout="$(jq -r '.timeout // 4' <<<"$monitor_json")"

  content="$(curl -ksS --max-time "$timeout" "$host" 2>/dev/null || true)"
  [[ -n "$content" ]] || return 1
  if [[ -n "$search" ]]; then
    [[ "$content" == *"$search"* ]]
  else
    return 0
  fi
}

Test_Host() {
  local monitor_json="$1"
  local type result
  type="$(monitor_type "$monitor_json")"

  case "$type" in
    ping) result="$(Test_Ping "$monitor_json" || true)" ;;
    website) Test_Website "$monitor_json"; result=$? ;;
    port) Test_Port "$monitor_json"; result=$? ;;
    *) result=1 ;;
  esac

  if [[ "$result" == 0 || -n "$result" ]]; then
    echo "Up:   $(jq -c '.' <<<"$monitor_json")"
  else
    echo "Down: $(jq -c '.' <<<"$monitor_json")"
  fi

  if [[ "$type" == "ping" && -n "$result" ]]; then
    printf '%s' "$result"
  else
    return "$result"
  fi
}

while true; do
  if [[ ! -f "$config_file" ]]; then
    echo "Config issue"
    sleep 2
    continue
  fi

  if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required"
    exit 1
  fi

  monitors_count="$(jq '.monitors | length' "$config_file" 2>/dev/null || echo 0)"
  echo "Total monitors: ${monitors_count}"

  push_url="$(jq -r '.settings.push_url // empty' "$config_file")"
  push_if_down="$(jq -r '.settings.push_if_down // true' "$config_file")"
  loop_enabled="$(jq -r '.settings.loop // true' "$config_file")"
  loop_delay="$(jq -r '.settings.loop_delay // 60' "$config_file")"

  jq -c '.monitors[]' "$config_file" | while IFS= read -r monitor; do
    message=""
    ping=0
    result=1

    if jq -e '.group? and (.group | length > 0)' >/dev/null <<<"$monitor"; then
      result=0
      down_message=""
      up_message=""
      monitor_id_val="$(monitor_id "$monitor")"
      group_count="$(jq '.group | length' <<<"$monitor")"
      echo "Group Monitor: id=${monitor_id_val} count=${group_count}"

      jq -c '.group[]' <<<"$monitor" | while IFS= read -r groupmonitor; do
        if ! member_result="$(Test_Host "$groupmonitor" 2>/dev/null)"; then
          result=1
          down_message+="$(monitor_type "$groupmonitor"):$((monitor_host "$groupmonitor"))  "
        else
          up_message+="$(monitor_type "$groupmonitor"):$((monitor_host "$groupmonitor"))  "
        fi
      done

      [[ -n "$down_message" ]] && message+="Down: ${down_message}"
      [[ -n "$up_message" ]] && message+="Up: ${up_message}"
    else
      if output="$(Test_Host "$monitor" 2>&1)"; then
        result=0
        if [[ "$output" =~ ^[0-9.]+$ ]]; then
          ping="$output"
        fi
      else
        result=1
      fi
      message="$(monitor_type "$monitor"):$(monitor_host "$monitor")"
    fi

    if [[ "$result" -eq 1 && "$push_if_down" == "false" ]]; then
      continue
    fi

    if [[ "$result" -eq 0 ]]; then
      status="up"
    else
      status="down"
    fi

    message_encoded="$(urlencode "$message")"
    push_url_updated="${push_url//\{ID\}/$(monitor_id "$monitor") }"
    push_url_updated="${push_url_updated//\{STATUS\}/$status}"
    push_url_updated="${push_url_updated//\{MSG\}/$message_encoded}"
    push_url_updated="${push_url_updated//\{PING\}/$ping}"

    push_url_updated="${push_url_updated// /}"

    if webrequest="$(curl -ksS "$push_url_updated" 2>&1)"; then
      echo "Push Response: $webrequest"
    else
      echo "Push Error: $webrequest"
    fi
  done

  if [[ "$loop_enabled" == "false" ]]; then
    exit 0
  fi

  echo "Sleeping for ${loop_delay} seconds"
  sleep "$loop_delay"
done
