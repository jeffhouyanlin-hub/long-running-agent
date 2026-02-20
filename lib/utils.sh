#!/usr/bin/env bash
# utils.sh — Shared utility functions for the long-running agent harness

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

log_header() {
    echo ""
    echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  $*${NC}"
    echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo ""
}

# Parse features.json and return "passed/total" counts
# Usage: check_features_progress /path/to/features.json
# Output: "passed total" (space-separated)
check_features_progress() {
    local features_file="$1"

    if [[ ! -f "$features_file" ]]; then
        echo "0 0"
        return 1
    fi

    local total passed
    total=$(jq '[.features[]] | length' "$features_file" 2>/dev/null || echo 0)
    passed=$(jq '[.features[] | select(.passes == true)] | length' "$features_file" 2>/dev/null || echo 0)

    echo "$passed $total"
}

# Append a session summary to the harness-level log
# Usage: log_session <log_file> <session_num> <passed> <total> <duration_secs> <exit_code>
log_session() {
    local log_file="$1"
    local session_num="$2"
    local passed="$3"
    local total="$4"
    local duration="$5"
    local exit_code="$6"

    local timestamp
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    local status="success"
    if [[ "$exit_code" -ne 0 ]]; then
        status="error (exit $exit_code)"
    fi

    cat >> "$log_file" <<EOF

--- Session $session_num [$timestamp] ---
Status: $status
Duration: ${duration}s
Features: $passed/$total passing
EOF
}

# Run a Claude session with the appropriate flags
# Usage: run_claude_session <prompt_file> <project_dir> <model> [extra_args...]
#
# A1: tmpfile + tail -f (no FIFO backpressure)
# A2: single jq per line (5→1 fork reduction)
# A3: process group kill via kill -- -PGID (clean child cleanup)
#
run_claude_session() {
    local prompt_file="$1"
    local project_dir="$2"
    local model="$3"
    shift 3
    local extra_args=()
    if [[ $# -gt 0 ]]; then
        extra_args=("$@")
    fi

    local prompt_content
    prompt_content=$(cat "$prompt_file")

    local cmd=(
        claude
        -p "$prompt_content"
        --model "$model"
        --verbose
        --output-format stream-json
        --dangerously-skip-permissions
    )

    # Add any extra args (e.g., --mcp-config)
    if [[ ${#extra_args[@]} -gt 0 ]]; then
        cmd+=("${extra_args[@]}")
    fi

    log_info "Running Claude session in $project_dir"
    log_info "Model: $model"
    log_info "Prompt: $prompt_file"

    local prev_dir
    prev_dir=$(pwd)
    cd "$project_dir"

    # --- Timeout Configuration ---
    local SESSION_TIMEOUT="${SESSION_TIMEOUT:-3600}"   # 60 min max wall-clock time
    local IDLE_TIMEOUT="${IDLE_TIMEOUT:-3600}"          # 60 min max with no output

    # Activity tracking for idle watchdog
    local activity_file
    activity_file=$(mktemp)
    touch "$activity_file"

    # --- A1: tmpfile replaces FIFO (no backpressure) ---
    local output_tmpfile
    output_tmpfile=$(mktemp)

    # --- A3: Variables for process group cleanup ---
    local claude_pid=""
    local claude_pgid=""
    local watchdog_pid=""
    local tail_pid=""

    # Trap to clean up on unexpected exit (SIGINT, SIGTERM, ERR)
    _session_cleanup() {
        local _wpid="${watchdog_pid:-}"
        local _tpid="${tail_pid:-}"
        local _cpid="${claude_pid:-}"
        local _cpgid="${claude_pgid:-}"

        # Kill watchdog
        if [[ -n "$_wpid" ]]; then
            kill "$_wpid" 2>/dev/null || true
            wait "$_wpid" 2>/dev/null || true
        fi

        # Kill tail reader
        if [[ -n "$_tpid" ]]; then
            kill "$_tpid" 2>/dev/null || true
            wait "$_tpid" 2>/dev/null || true
        fi

        # A3: Kill entire process group (catches gradle/node/etc.)
        if [[ -n "$_cpgid" ]] && [[ "$_cpgid" != "0" ]]; then
            kill -TERM -- "-$_cpgid" 2>/dev/null || true
            sleep 1
            kill -KILL -- "-$_cpgid" 2>/dev/null || true
        elif [[ -n "$_cpid" ]]; then
            kill "$_cpid" 2>/dev/null || true
        fi

        [[ -n "$_cpid" ]] && wait "$_cpid" 2>/dev/null || true

        rm -f "${output_tmpfile:-}" "${activity_file:-}"
    }
    trap _session_cleanup EXIT

    # --- Real-time session log for monitor ---
    local session_log="$project_dir/.harness-live.jsonl"
    : > "$session_log"  # truncate

    # --- A1+A3: Start Claude with output to tmpfile, in new process group ---
    set -m  # enable job control for process groups
    "${cmd[@]}" > "$output_tmpfile" 2>&1 &
    claude_pid=$!
    # Get process group ID (macOS + Linux compatible)
    claude_pgid=$(ps -o pgid= -p "$claude_pid" 2>/dev/null | tr -d ' ' || echo "")
    set +m  # restore

    log_info "Claude PID: $claude_pid, PGID: ${claude_pgid:-unknown}"

    # --- Watchdog: checked every 15s (was 60s) ---
    (
        local start_time
        start_time=$(date +%s)
        while kill -0 "$claude_pid" 2>/dev/null; do
            sleep 15
            local now
            now=$(date +%s)

            # Check hard wall-clock timeout
            local elapsed=$(( now - start_time ))
            if [[ $elapsed -gt $SESSION_TIMEOUT ]]; then
                echo -e "${YELLOW}[WARN]${NC} Watchdog: session exceeded ${SESSION_TIMEOUT}s wall-clock limit, killing PGID=${claude_pgid}" >&2
                if [[ -n "$claude_pgid" ]] && [[ "$claude_pgid" != "0" ]]; then
                    kill -TERM -- "-$claude_pgid" 2>/dev/null || true
                    sleep 1
                    kill -KILL -- "-$claude_pgid" 2>/dev/null || true
                else
                    kill "$claude_pid" 2>/dev/null || true
                fi
                break
            fi

            # Check idle timeout (no output for IDLE_TIMEOUT seconds)
            if [[ -f "$activity_file" ]]; then
                local last_mod idle_secs
                last_mod=$(stat -f %m "$activity_file" 2>/dev/null \
                        || stat -c %Y "$activity_file" 2>/dev/null \
                        || echo 0)
                idle_secs=$(( now - last_mod ))
                if [[ $idle_secs -gt $IDLE_TIMEOUT ]]; then
                    echo -e "${YELLOW}[WARN]${NC} Watchdog: no output for ${idle_secs}s (limit: ${IDLE_TIMEOUT}s), killing PGID=${claude_pgid}" >&2
                    if [[ -n "$claude_pgid" ]] && [[ "$claude_pgid" != "0" ]]; then
                        kill -TERM -- "-$claude_pgid" 2>/dev/null || true
                        sleep 1
                        kill -KILL -- "-$claude_pgid" 2>/dev/null || true
                    else
                        kill "$claude_pid" 2>/dev/null || true
                    fi
                    break
                fi
            fi
        done
    ) &
    watchdog_pid=$!

    # --- A1: Read via tail -f (no backpressure on Claude) ---
    local exit_code=0
    tail -f "$output_tmpfile" &
    tail_pid=$!

    # Parse stream-json from tmpfile: poll until Claude exits
    local last_pos=0
    while kill -0 "$claude_pid" 2>/dev/null || [[ $(wc -c < "$output_tmpfile") -gt $last_pos ]]; do
        local current_size
        current_size=$(wc -c < "$output_tmpfile")

        if [[ $current_size -le $last_pos ]]; then
            sleep 0.5
            continue
        fi

        # Read new lines since last_pos
        while IFS= read -r line; do
            touch "$activity_file"  # record activity for watchdog

            # A2: Fast-path filter — skip lines without "type"
            if [[ "$line" != *'"type"'* ]]; then
                continue
            fi

            local ts
            ts=$(date '+%H:%M:%S')

            # A2: Single jq call extracts all fields at once
            local parsed
            parsed=$(echo "$line" | jq -r '
                .type as $t |
                if $t == "assistant" then
                    [
                        $t,
                        ([.message.content[]? | select(.type == "text") | .text] | join(" ") | .[0:200]),
                        ([.message.content[]? | select(.type == "tool_use") | .name] | join(",")),
                        (.message.usage.input_tokens // 0 | tostring),
                        (.message.usage.output_tokens // 0 | tostring),
                        ""
                    ]
                elif $t == "result" then
                    [
                        $t,
                        "",
                        "",
                        (.usage.input_tokens // 0 | tostring),
                        (.usage.output_tokens // 0 | tostring),
                        (.is_error // false | tostring)
                    ]
                else
                    [$t, "", "", "0", "0", ""]
                end | @tsv
            ' 2>/dev/null || true)

            if [[ -z "$parsed" ]]; then
                continue
            fi

            local msg_type text tool_names input_tokens output_tokens is_error
            IFS=$'\t' read -r msg_type text tool_names input_tokens output_tokens is_error <<< "$parsed"

            # A4 (bonus): Write valid JSONL via jq instead of printf
            case "$msg_type" in
                assistant)
                    jq -n --arg ts "$ts" --arg text "${text:0:150}" \
                        --arg tools "${tool_names:-}" \
                        --argjson in "${input_tokens:-0}" --argjson out "${output_tokens:-0}" \
                        '{ts:$ts,type:"assistant",input_tokens:$in,output_tokens:$out,tools:$tools,text:$text}' \
                        >> "$session_log"

                    if [[ -n "$text" ]]; then
                        echo -e "${BLUE}[Claude]${NC} ${text:0:200}"
                    fi
                    if [[ -n "$tool_names" ]]; then
                        echo -e "${YELLOW}[Tool]${NC} $tool_names"
                    fi
                    ;;
                result)
                    jq -n --arg ts "$ts" \
                        --argjson in "${input_tokens:-0}" --argjson out "${output_tokens:-0}" \
                        --argjson err "${is_error:-false}" \
                        '{ts:$ts,type:"result",is_error:$err,input_tokens:$in,output_tokens:$out}' \
                        >> "$session_log"

                    if [[ "$is_error" == "true" ]]; then
                        log_error "Session ended with error"
                    else
                        log_info "Session completed successfully."
                    fi
                    # Signal done — Claude should exit shortly
                    ;;
                *)
                    if [[ -n "$msg_type" ]]; then
                        jq -n --arg ts "$ts" --arg type "$msg_type" \
                            '{ts:$ts,type:$type}' >> "$session_log"
                    fi
                    ;;
            esac
        done < <(tail -c +"$((last_pos + 1))" "$output_tmpfile" 2>/dev/null)

        last_pos=$current_size
        sleep 0.3
    done

    # Process remaining output after Claude exits
    local final_size
    final_size=$(wc -c < "$output_tmpfile")
    if [[ $final_size -gt $last_pos ]]; then
        while IFS= read -r line; do
            if [[ "$line" != *'"type"'* ]]; then continue; fi
            local ts
            ts=$(date '+%H:%M:%S')
            local parsed
            parsed=$(echo "$line" | jq -r '
                .type as $t |
                if $t == "result" then
                    [$t, "", "", (.usage.input_tokens // 0 | tostring), (.usage.output_tokens // 0 | tostring), (.is_error // false | tostring)]
                else
                    [$t, "", "", "0", "0", ""]
                end | @tsv
            ' 2>/dev/null || true)
            if [[ -n "$parsed" ]]; then
                local msg_type text tool_names input_tokens output_tokens is_error
                IFS=$'\t' read -r msg_type text tool_names input_tokens output_tokens is_error <<< "$parsed"
                if [[ "$msg_type" == "result" ]]; then
                    jq -n --arg ts "$ts" \
                        --argjson in "${input_tokens:-0}" --argjson out "${output_tokens:-0}" \
                        --argjson err "${is_error:-false}" \
                        '{ts:$ts,type:"result",is_error:$err,input_tokens:$in,output_tokens:$out}' \
                        >> "$session_log"
                    if [[ "$is_error" == "true" ]]; then
                        log_error "Session ended with error"
                    else
                        log_info "Session completed successfully."
                    fi
                fi
            fi
        done < <(tail -c +"$((last_pos + 1))" "$output_tmpfile" 2>/dev/null)
    fi

    # --- Cleanup ---
    # Kill tail reader
    kill "$tail_pid" 2>/dev/null || true
    wait "$tail_pid" 2>/dev/null || true

    # A3: Kill entire process group
    kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
    if [[ -n "$claude_pgid" ]] && [[ "$claude_pgid" != "0" ]]; then
        kill -TERM -- "-$claude_pgid" 2>/dev/null || true
        sleep 1
        kill -KILL -- "-$claude_pgid" 2>/dev/null || true
    else
        kill "$claude_pid" 2>/dev/null || true
    fi
    wait "$claude_pid" 2>/dev/null || true
    rm -f "$output_tmpfile" "$activity_file"

    # Remove the EXIT trap so it doesn't fire again
    trap - EXIT

    cd "$prev_dir"
    return $exit_code
}

# Validate that required artifacts exist in the project directory
# Usage: validate_artifacts <project_dir>
# Returns 0 if all artifacts exist, 1 otherwise
validate_artifacts() {
    local project_dir="$1"
    local missing=0

    for artifact in init.sh features.json claude-progress.txt; do
        if [[ ! -f "$project_dir/$artifact" ]]; then
            log_warn "Missing artifact: $artifact"
            missing=1
        fi
    done

    if [[ ! -d "$project_dir/.git" ]]; then
        log_warn "Missing git repository in $project_dir"
        missing=1
    fi

    return $missing
}

# Get a human-readable progress bar
# Usage: progress_bar <current> <total> [width]
progress_bar() {
    local current="$1"
    local total="$2"
    local width="${3:-40}"

    if [[ "$total" -eq 0 ]]; then
        echo "[$(printf '%*s' "$width" | tr ' ' '-')]  0/0"
        return
    fi

    local filled=$(( current * width / total ))
    local empty=$(( width - filled ))

    printf '[%s%s] %d/%d' \
        "$(printf '%*s' "$filled" | tr ' ' '#')" \
        "$(printf '%*s' "$empty" | tr ' ' '-')" \
        "$current" "$total"
}
