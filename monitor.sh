#!/usr/bin/env bash
# monitor.sh — Real-time harness monitor (zero tokens, pure shell)
#
# Detects all programming states by checking:
#   1. Claude process alive?
#   2. What child processes are running?
#   3. Stream-json output freshness
#   4. Project files being modified?
#   5. Harness log status
#
# Usage:
#   ./monitor.sh /path/to/project

set -euo pipefail

# ─── Config ─────────────────────────────────────────────────────────────────

REFRESH=10

# ─── Colors ─────────────────────────────────────────────────────────────────

R='\033[0;31m'   G='\033[0;32m'   Y='\033[1;33m'
B='\033[0;34m'   C='\033[0;36m'   W='\033[1;37m'
M='\033[0;35m'   DIM='\033[2m'    BOLD='\033[1m'   NC='\033[0m'
BG_R='\033[41m'  BG_G='\033[42m'  BG_Y='\033[43m'  BG_C='\033[46m'

# ─── Args ───────────────────────────────────────────────────────────────────

PROJECT_DIR="${1:-./project}"

if [[ ! -d "$PROJECT_DIR" ]]; then
    echo -e "${R}Error: Project directory not found: $PROJECT_DIR${NC}"
    exit 1
fi

FEATURES_FILE="$PROJECT_DIR/features.json"
HARNESS_LOG="$PROJECT_DIR/harness-log.txt"
PROGRESS_FILE="$PROJECT_DIR/claude-progress.txt"
LIVE_LOG="$PROJECT_DIR/.harness-live.jsonl"

# ─── Helpers ────────────────────────────────────────────────────────────────

detect_output_file() {
    local uid
    uid=$(id -u)
    ls -t /private/tmp/claude-"$uid"/*/tasks/*.output \
          /private/tmp/claude-*/tasks/*.output \
          /tmp/claude-*/tasks/*.output 2>/dev/null | head -1 || true
}

get_file_age() {
    local file="$1"
    if [[ ! -f "$file" ]]; then echo "999999"; return; fi
    local now mod
    now=$(date +%s)
    mod=$(stat -f %m "$file" 2>/dev/null || stat -c %Y "$file" 2>/dev/null || echo "$now")
    echo $(( now - mod ))
}

# Check if any file in project was modified within last N seconds
project_files_changing() {
    local dir="$1"
    local within="${2:-30}"
    local now
    now=$(date +%s)
    local src_dirs=("$dir/src" "$dir/app/src" "$dir/lib" "$dir/test" "$dir/tests")
    for d in "${src_dirs[@]}"; do
        if [[ -d "$d" ]]; then
            local newest
            newest=$(find "$d" -type f \( -name "*.kt" -o -name "*.ts" -o -name "*.tsx" -o -name "*.js" -o -name "*.py" -o -name "*.java" \) -exec stat -f %m {} \; 2>/dev/null | sort -rn | head -1 || true)
            if [[ -n "$newest" ]] && (( now - newest < within )); then
                return 0
            fi
        fi
    done
    return 1
}

fmt_dur() {
    local s=$1
    if (( s < 60 )); then echo "${s}s"
    elif (( s < 3600 )); then echo "$((s/60))m$((s%60))s"
    else echo "$((s/3600))h$((s%3600/60))m"
    fi
}

fmt_tokens() {
    local t=$1
    if (( t >= 1000000 )); then echo "$(echo "scale=1;$t/1000000" | bc)M"
    elif (( t >= 1000 )); then echo "$(echo "scale=1;$t/1000" | bc)K"
    else echo "$t"
    fi
}

progress_bar() {
    local cur="$1"
    local tot="$2"
    local w="${3:-30}"
    if (( tot == 0 )); then printf '[%*s]' "$w" '' | tr ' ' '·'; return; fi
    local filled=$(( cur * w / tot ))
    local empty=$(( w - filled ))
    printf '[%s%s]' "$(printf '%*s' "$filled" | tr ' ' '█')" "$(printf '%*s' "$empty" | tr ' ' '·')"
}

detect_phase() {
    local file="$1"
    if [[ ! -f "$file" ]]; then echo "—"; return; fi
    if grep -q "ALL FEATURES PASSING" "$file" 2>/dev/null; then echo "COMPLETE"
    elif grep -q "Phase 2" "$file" 2>/dev/null; then
        grep -o "Coding Session [0-9]*/[0-9]*\|Coding Session [0-9]* / [0-9]*" "$file" 2>/dev/null | tail -1 || echo "Phase 2"
    elif grep -q "Phase 1" "$file" 2>/dev/null; then echo "Phase 1: Initializer"
    else echo "Starting"
    fi
}

# ─── Core: State Detection Engine ───────────────────────────────────────────
#
# Returns: STATE_ICON STATE_LABEL STATE_DETAIL
#
# Detection matrix (priority order):
#
#   Condition                                  → State
#   ──────────────────────────────────────────────────────────────
#   All features passing                       → ✅ COMPLETE
#   Harness log says consecutive failures      → 🔴 STOPPED (failures)
#   ──────────────────────────────────────────────────────────────
#   Claude alive + gradle test running         → ⏳ TESTING (gradle)
#   Claude alive + gradle build/compile        → 🔨 BUILDING (gradle)
#   Claude alive + gradle assemble             → 📦 ASSEMBLING (gradle)
#   Claude alive + npm/vitest/jest running     → ⏳ TESTING (npm)
#   Claude alive + npm install/pip install     → 📥 INSTALLING deps
#   Claude alive + tsc/vite build              → 🔨 COMPILING
#   Claude alive + eslint/ktlint              → 🔍 LINTING
#   Claude alive + git running                 → 📦 GIT operation
#   Claude alive + output < 30s               → 🔄 CODING (active)
#   Claude alive + files changing              → ✏️  WRITING code
#   Claude alive + output 30s-5m              → 🧠 THINKING
#   Claude alive + output 5m-20m              → ⚠️  LONG WAIT
#   Claude alive + output > 20m               → 🔴 LIKELY STUCK
#   ──────────────────────────────────────────────────────────────
#   Claude dead + output < 60s                 → 🔄 BETWEEN SESSIONS
#   Claude dead + backoff pattern in log       → ⏸️  RATE LIMITED
#   Claude dead + output 1m-5m                → 🟡 SESSION GAP
#   Claude dead + output > 5m                 → 🔴 NOT RUNNING
#

detect_state() {
    local output_age="$1"

    # --- Check harness completion ---
    if [[ -f "$HARNESS_LOG" ]] && grep -q "completed" "$HARNESS_LOG" 2>/dev/null; then
        echo "✅" "COMPLETE" "All features passing"
        return
    fi

    # --- Check Claude process ---
    claude_pid=""
    claude_pid=$(pgrep -f "claude.*-p.*" 2>/dev/null | head -1 || true)
    claude_alive=false
    if [[ -n "$claude_pid" ]]; then
        claude_alive=true
    fi

    # --- If Claude is alive, check what it's doing ---
    if [[ "$claude_alive" == true ]]; then

        # Check child processes (subprocess detection)
        if pgrep -f "gradlew.*test\|gradle.*test" >/dev/null 2>&1; then
            echo "⏳" "TESTING" "gradle test running"
            return
        fi
        if pgrep -f "gradlew.*build\|gradle.*build" >/dev/null 2>&1; then
            echo "🔨" "BUILDING" "gradle build running"
            return
        fi
        if pgrep -f "gradlew.*assemble\|gradle.*assemble" >/dev/null 2>&1; then
            echo "📦" "ASSEMBLING" "gradle assemble running"
            return
        fi
        if pgrep -f "gradlew.*compile\|gradle.*compile" >/dev/null 2>&1; then
            echo "🔨" "COMPILING" "gradle compile running"
            return
        fi
        if pgrep -f "vitest\|jest.*--run\|npm test\|npx test" >/dev/null 2>&1; then
            echo "⏳" "TESTING" "npm/vitest running"
            return
        fi
        if pgrep -f "npm install\|pip install\|yarn install\|pnpm install" >/dev/null 2>&1; then
            echo "📥" "INSTALLING" "dependency install"
            return
        fi
        if pgrep -f "tsc\b\|vite build\|webpack" >/dev/null 2>&1; then
            echo "🔨" "COMPILING" "TypeScript/bundler"
            return
        fi
        if pgrep -f "eslint\|ktlint\|prettier" >/dev/null 2>&1; then
            echo "🔍" "LINTING" "code analysis"
            return
        fi
        if pgrep -f "git commit\|git push\|git add" >/dev/null 2>&1; then
            echo "📦" "GIT" "committing changes"
            return
        fi

        # No known subprocess — check output freshness
        if (( output_age < 30 )); then
            echo "🔄" "CODING" "active output"
            return
        fi

        # Check if source files are being modified
        if project_files_changing "$PROJECT_DIR" 30; then
            echo "✏️ " "WRITING" "modifying source files"
            return
        fi

        if (( output_age < 300 )); then
            echo "🧠" "THINKING" "no output for $(fmt_dur "$output_age")"
            return
        fi

        if (( output_age < 1200 )); then
            echo "⚠️ " "LONG WAIT" "no output for $(fmt_dur "$output_age")"
            return
        fi

        echo "🔴" "LIKELY STUCK" "Claude alive but silent $(fmt_dur "$output_age")"
        return
    fi

    # --- Claude is NOT alive ---

    # Check if between sessions (harness cycling)
    if (( output_age < 60 )); then
        echo "🔄" "BETWEEN SESSIONS" "preparing next session"
        return
    fi

    # Check for rate limit / backoff pattern
    if [[ -f "$HARNESS_LOG" ]] && tail -3 "$HARNESS_LOG" 2>/dev/null | grep -q "rate limited\|Waiting.*retry\|error.*exit"; then
        echo "⏸️ " "RATE LIMITED" "backoff wait"
        return
    fi

    if (( output_age < 300 )); then
        echo "🟡" "SESSION GAP" "$(fmt_dur "$output_age") since last activity"
        return
    fi

    echo "🔴" "NOT RUNNING" "no activity for $(fmt_dur "$output_age")"
}

# ─── Main Loop ──────────────────────────────────────────────────────────────

trap 'tput cnorm 2>/dev/null; echo ""; exit 0' INT TERM
tput civis 2>/dev/null

while true; do
    clear

    OUTPUT_FILE=$(detect_output_file)
    PHASE=$(detect_phase "$OUTPUT_FILE")

    # Determine output age
    if [[ -f "$LIVE_LOG" && -s "$LIVE_LOG" ]]; then
        output_age=$(get_file_age "$LIVE_LOG")
    elif [[ -n "$OUTPUT_FILE" && -f "$OUTPUT_FILE" ]]; then
        output_age=$(get_file_age "$OUTPUT_FILE")
    else
        output_age=999999
    fi

    # Detect state
    read -r state_icon state_label state_detail <<< "$(detect_state "$output_age")"

    # ── Header ──
    echo -e "${BOLD}${C}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${C}║${NC}  ${BOLD}Harness Monitor${NC}                           ${DIM}$(date '+%H:%M:%S')${NC}  ${BOLD}${C}║${NC}"
    echo -e "${BOLD}${C}╚════════════════════════════════════════════════════════════════╝${NC}"

    # ── Status Line (most important — always visible at top) ──
    case "$state_label" in
        COMPLETE)     echo -e "  ${BG_G}${W} ${state_icon} ${state_label} ${NC}  ${state_detail}" ;;
        CODING|WRITING|THINKING)
                      echo -e "  ${G}${state_icon}${NC} ${BOLD}${state_label}${NC}  ${DIM}${state_detail}${NC}  ${DIM}│${NC} ${PHASE}" ;;
        TESTING|BUILDING|COMPILING|ASSEMBLING|INSTALLING|LINTING|GIT)
                      echo -e "  ${C}${state_icon}${NC} ${BOLD}${state_label}${NC}  ${C}${state_detail}${NC}  ${DIM}│${NC} ${PHASE}" ;;
        BETWEEN*|SESSION*)
                      echo -e "  ${Y}${state_icon}${NC} ${BOLD}${state_label}${NC}  ${DIM}${state_detail}${NC}  ${DIM}│${NC} ${PHASE}" ;;
        "RATE LIMITED")
                      echo -e "  ${Y}${state_icon}${NC} ${BOLD}${state_label}${NC}  ${Y}${state_detail}${NC}  ${DIM}│${NC} ${PHASE}" ;;
        "LONG WAIT")  echo -e "  ${Y}${state_icon}${NC} ${BOLD}${state_label}${NC}  ${Y}${state_detail}${NC}  ${DIM}│${NC} ${PHASE}" ;;
        "LIKELY STUCK"|"NOT RUNNING"|STOPPED)
                      echo -e "  ${BG_R}${W} ${state_icon} ${state_label} ${NC}  ${R}${state_detail}${NC}" ;;
        *)            echo -e "  ${state_icon} ${BOLD}${state_label}${NC}  ${DIM}${state_detail}${NC}" ;;
    esac
    echo ""

    # ── Token Usage ──
    echo -e "${BOLD}  Tokens${NC}"
    if [[ -f "$LIVE_LOG" && -s "$LIVE_LOG" ]]; then
        live_stats=$(jq -s -r '
            (map(select(.input_tokens != null) | .input_tokens) | add // 0) as $in |
            (map(select(.output_tokens != null) | .output_tokens) | add // 0) as $out |
            length as $ev |
            "\($in) \($out) \($ev)"
        ' "$LIVE_LOG" 2>/dev/null || echo "0 0 0")
        read -r live_in live_out live_ev <<< "$live_stats"
        live_total=$(( live_in + live_out ))
        session_cost=$(echo "scale=3; $live_in * 0.000003 + $live_out * 0.000015" | bc 2>/dev/null || echo "?")
        echo -e "    Session:  ${C}↓$(fmt_tokens "$live_in")${NC} in  ${Y}↑$(fmt_tokens "$live_out")${NC} out  ${W}Σ$(fmt_tokens "$live_total")${NC}  ${DIM}(\$${session_cost})${NC}  ${DIM}${live_ev} calls${NC}"
    else
        echo -e "    Session:  ${DIM}(no live data — starts from next session)${NC}"
    fi
    if [[ -f "$HARNESS_LOG" ]]; then
        sessions_done=$(grep -c "^--- Session" "$HARNESS_LOG" 2>/dev/null; true)
        sessions_done=${sessions_done:-0}
        total_dur=0
        while IFS= read -r dur; do
            d=$(echo "$dur" | sed 's/[^0-9]//g')
            if [[ -n "$d" ]]; then total_dur=$(( total_dur + d )); fi
        done < <(grep "^Duration:" "$HARNESS_LOG" 2>/dev/null | awk '{print $2}')
        if (( sessions_done > 0 )); then
            cum_cost=$(echo "scale=2; $total_dur * 0.008" | bc 2>/dev/null || echo "?")
            echo -e "    Total:    ${DIM}${sessions_done} sessions  $(fmt_dur "$total_dur")  ~\$${cum_cost}${NC}"
        fi
    fi
    echo ""

    # ── Features ──
    echo -e "${BOLD}  Features${NC}"
    if [[ -f "$FEATURES_FILE" ]]; then
        total=$(jq '[.features[]] | length' "$FEATURES_FILE" 2>/dev/null || echo 0)
        passed=$(jq '[.features[] | select(.passes == true)] | length' "$FEATURES_FILE" 2>/dev/null || echo 0)
        pct=0; if (( total > 0 )); then pct=$(( passed * 100 / total )); fi
        echo -e "    $(progress_bar "$passed" "$total" 35)  ${W}${passed}${NC}/${total}  ${G}${pct}%${NC}"

        # Two-column category view
        jq -r '
            [.features[] | {cat: .category, p: .passes}]
            | group_by(.cat)
            | map({cat: .[0].cat, total: length, pass: [.[] | select(.p == true)] | length})
            | sort_by(.cat)
            | .[]
            | (if .pass == .total then "✓" elif .pass > 0 then "◐" else "○" end)
              + " " + (.cat + "              " | .[:14])
              + (.pass | tostring) + "/" + (.total | tostring)
        ' "$FEATURES_FILE" 2>/dev/null | \
        paste - - 2>/dev/null | \
        while IFS=$'\t' read -r c1 c2; do
            printf "    %-22s %s\n" "$c1" "${c2:-}"
        done
    else
        echo -e "    ${DIM}features.json not yet created${NC}"
    fi
    echo ""

    # ── Live Actions ──
    echo -e "${BOLD}  Actions${NC}"
    if [[ -f "$LIVE_LOG" && -s "$LIVE_LOG" ]]; then
        jq -r '
            if .tools != null and .tools != "" then
                "\(.ts) \u001b[1;33m⚡ \(.tools)\u001b[0m"
            elif .text != null and .text != "" then
                "\(.ts) \u001b[0;34m💬 \(.text[:60])\u001b[0m"
            elif .type == "result" then
                if .is_error == true then
                    "\(.ts) \u001b[0;31m✗ Error (in:\(.input_tokens) out:\(.output_tokens))\u001b[0m"
                else
                    "\(.ts) \u001b[0;32m✓ Done (in:\(.input_tokens) out:\(.output_tokens))\u001b[0m"
                end
            else empty end
        ' "$LIVE_LOG" 2>/dev/null | tail -6 | while IFS= read -r line; do
            echo -e "    $line"
        done
    else
        # Fall back to harness output
        if [[ -n "$OUTPUT_FILE" && -f "$OUTPUT_FILE" ]]; then
            tail -15 "$OUTPUT_FILE" 2>/dev/null | \
                sed 's/\x1b\[[0-9;]*m//g' | grep -v '^$' | tail -6 | \
                while IFS= read -r line; do echo -e "    ${DIM}${line:0:65}${NC}"; done
        else
            echo -e "    ${DIM}(no data)${NC}"
        fi
    fi
    echo ""

    # ── Bottom Bar ──
    model=$(grep "^Model:" "$HARNESS_LOG" 2>/dev/null | head -1 | awk '{print $2}')
    commits=$(git -C "$PROJECT_DIR" rev-list --count HEAD 2>/dev/null || echo 0)
    last_msg=$(git -C "$PROJECT_DIR" log --format='%s' -1 2>/dev/null || echo "—")
    out_id=$(basename "${OUTPUT_FILE:-none}" .output)

    # Output file stall indicator
    if [[ -n "$OUTPUT_FILE" && -f "$OUTPUT_FILE" ]]; then
        file_age=$(get_file_age "$OUTPUT_FILE")
        if (( file_age < 30 )); then
            out_status="${G}● ACTIVE${NC}"
        elif (( file_age < 120 )); then
            out_status="${G}● $(fmt_dur "$file_age")${NC}"
        elif (( file_age < 300 )); then
            out_status="${Y}⚠ SLOW $(fmt_dur "$file_age")${NC}"
        else
            out_status="${R}✗ STALE $(fmt_dur "$file_age")${NC}"
        fi
    else
        out_status="${DIM}no output${NC}"
    fi

    echo -e "${DIM}  ──────────────────────────────────────────────────────────────${NC}"
    echo -e "  ${DIM}model:${NC}${C}${model:-?}${NC} ${DIM}commits:${NC}${W}${commits}${NC} ${DIM}output:${NC}${out_status} ${DIM}id:${NC}${DIM}${out_id:0:8}${NC}"
    echo -e "  ${DIM}last commit: ${last_msg:0:55}${NC}"

    # ── Animated Countdown Bar (last line, uses \r for universal compatibility) ──
    BAR_WIDTH=50
    for (( i=REFRESH; i>0; i-- )); do
        bar_filled=$(( (REFRESH - i + 1) * BAR_WIDTH / REFRESH ))
        bar_empty=$(( BAR_WIDTH - bar_filled ))
        printf "\r  \033[0;32m%s\033[2m%s\033[0m \033[2m%ds\033[0m  " \
            "$(printf '%*s' "$bar_filled" | tr ' ' '━')" \
            "$(printf '%*s' "$bar_empty" | tr ' ' '╌')" \
            "$i"
        sleep 1
    done
    printf "\r  \033[0;32m%s\033[0m \033[2m 0s\033[0m  " \
        "$(printf '%*s' "$BAR_WIDTH" | tr ' ' '━')"
done
