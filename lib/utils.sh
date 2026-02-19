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
    local SESSION_TIMEOUT="${SESSION_TIMEOUT:-3600}"  # 60 min max wall-clock time
    local IDLE_TIMEOUT="${IDLE_TIMEOUT:-3600}"          # 60 min max with no output (Gradle builds need time)

    # Activity tracking for idle watchdog
    local activity_file
    activity_file=$(mktemp)
    touch "$activity_file"

    # Named pipe so we can decouple Claude from the read loop
    local fifo
    fifo=$(mktemp -u)
    mkfifo "$fifo"

    # Trap to clean up on unexpected exit (SIGINT, SIGTERM, ERR)
    _session_cleanup() {
        kill "$claude_pid" 2>/dev/null || true
        kill "$watchdog_pid" 2>/dev/null || true
        wait "$claude_pid" 2>/dev/null || true
        wait "$watchdog_pid" 2>/dev/null || true
        rm -f "$fifo" "$activity_file"
    }
    trap _session_cleanup EXIT

    # Start Claude (no external timeout command needed), output to fifo
    "${cmd[@]}" > "$fifo" 2>&1 &
    local claude_pid=$!

    # --- Combined Watchdog (Solution A + C) ---
    # Two kill conditions, checked every 60s:
    #   1. Hard wall-clock limit (SESSION_TIMEOUT) — prevents runaway sessions
    #   2. Idle limit (IDLE_TIMEOUT) — kills if no output for too long
    (
        local start_time
        start_time=$(date +%s)
        while kill -0 "$claude_pid" 2>/dev/null; do
            sleep 60
            local now
            now=$(date +%s)

            # Check hard wall-clock timeout
            local elapsed=$(( now - start_time ))
            if [[ $elapsed -gt $SESSION_TIMEOUT ]]; then
                echo -e "${YELLOW}[WARN]${NC} Watchdog: session exceeded ${SESSION_TIMEOUT}s wall-clock limit, killing" >&2
                kill "$claude_pid" 2>/dev/null || true
                break
            fi

            # Check idle timeout (no output for IDLE_TIMEOUT seconds)
            if [[ -f "$activity_file" ]]; then
                local last_mod idle_secs
                # macOS (BSD stat) then Linux fallback
                last_mod=$(stat -f %m "$activity_file" 2>/dev/null \
                        || stat -c %Y "$activity_file" 2>/dev/null \
                        || echo 0)
                idle_secs=$(( now - last_mod ))
                if [[ $idle_secs -gt $IDLE_TIMEOUT ]]; then
                    echo -e "${YELLOW}[WARN]${NC} Watchdog: no output for ${idle_secs}s (limit: ${IDLE_TIMEOUT}s), killing session" >&2
                    kill "$claude_pid" 2>/dev/null || true
                    break
                fi
            fi
        done
    ) &
    local watchdog_pid=$!

    # --- Real-time session log for monitor ---
    local session_log="$project_dir/.harness-live.jsonl"
    : > "$session_log"  # truncate

    # --- Parse stream-json output (Solution A) ---
    local exit_code=0
    while IFS= read -r line; do
        touch "$activity_file"  # record activity for watchdog
        local msg_type
        msg_type=$(echo "$line" | jq -r '.type // empty' 2>/dev/null || true)

        # Write every event to live log for monitor consumption
        local ts
        ts=$(date '+%H:%M:%S')

        case "$msg_type" in
            assistant)
                local text tool_names input_tokens output_tokens
                text=$(echo "$line" | jq -r '.message.content[]? | select(.type == "text") | .text' 2>/dev/null || true)
                tool_names=$(echo "$line" | jq -r '[.message.content[]? | select(.type == "tool_use") | .name] | join(",")' 2>/dev/null || true)
                input_tokens=$(echo "$line" | jq -r '.message.usage.input_tokens // 0' 2>/dev/null || echo 0)
                output_tokens=$(echo "$line" | jq -r '.message.usage.output_tokens // 0' 2>/dev/null || echo 0)

                # Write structured event to live log
                printf '{"ts":"%s","type":"assistant","input_tokens":%s,"output_tokens":%s,"tools":"%s","text":"%s"}\n' \
                    "$ts" "$input_tokens" "$output_tokens" "$tool_names" \
                    "$(echo "${text:0:150}" | sed 's/"/\\"/g' | tr '\n' ' ')" \
                    >> "$session_log"

                if [[ -n "$text" ]]; then
                    echo -e "${BLUE}[Claude]${NC} ${text:0:200}"
                fi
                if [[ -n "$tool_names" ]]; then
                    echo -e "${YELLOW}[Tool]${NC} $tool_names"
                fi
                ;;
            result)
                local is_error result_input result_output
                is_error=$(echo "$line" | jq -r '.is_error // false' 2>/dev/null || echo false)
                result_input=$(echo "$line" | jq -r '.usage.input_tokens // 0' 2>/dev/null || echo 0)
                result_output=$(echo "$line" | jq -r '.usage.output_tokens // 0' 2>/dev/null || echo 0)

                printf '{"ts":"%s","type":"result","is_error":%s,"input_tokens":%s,"output_tokens":%s}\n' \
                    "$ts" "$is_error" "$result_input" "$result_output" \
                    >> "$session_log"

                if [[ "$is_error" == "true" ]]; then
                    log_error "Session ended with error"
                else
                    log_info "Session completed successfully."
                fi
                break  # ← Exit immediately after receiving result
                ;;
            *)
                # Log other event types (system, etc.)
                if [[ -n "$msg_type" ]]; then
                    printf '{"ts":"%s","type":"%s"}\n' "$ts" "$msg_type" >> "$session_log"
                fi
                ;;
        esac
    done < "$fifo" || exit_code=$?

    # Cleanup: kill Claude if still running (expected after break)
    kill "$claude_pid" 2>/dev/null || true
    kill "$watchdog_pid" 2>/dev/null || true
    wait "$claude_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
    rm -f "$fifo" "$activity_file"

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
