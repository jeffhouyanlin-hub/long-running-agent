#!/usr/bin/env bash
# monitor.sh — Real-time harness monitor (zero tokens, pure shell)
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
STATE_FILE="$PROJECT_DIR/.harness-state.json"
TMPFILE_PTR="$PROJECT_DIR/.harness-tmpfile"

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

detect_state() {
    local output_age="$1"

    if [[ -f "$HARNESS_LOG" ]] && grep -q "completed" "$HARNESS_LOG" 2>/dev/null; then
        echo "✅" "COMPLETE" "All features passing"
        return
    fi

    claude_pid=""
    claude_pid=$(pgrep -f "claude.*-p.*" 2>/dev/null | head -1 || true)
    claude_alive=false
    if [[ -n "$claude_pid" ]]; then
        claude_alive=true
    fi

    if [[ "$claude_alive" == true ]]; then
        if pgrep -f "gradlew.*test\|gradle.*test" >/dev/null 2>&1; then
            echo "⏳" "TESTING" "gradle test running"; return; fi
        if pgrep -f "gradlew.*build\|gradle.*build" >/dev/null 2>&1; then
            echo "🔨" "BUILDING" "gradle build running"; return; fi
        if pgrep -f "gradlew.*assemble\|gradle.*assemble" >/dev/null 2>&1; then
            echo "📦" "ASSEMBLING" "gradle assemble running"; return; fi
        if pgrep -f "gradlew.*compile\|gradle.*compile" >/dev/null 2>&1; then
            echo "🔨" "COMPILING" "gradle compile running"; return; fi
        if pgrep -f "vitest\|jest.*--run\|npm test\|npx test" >/dev/null 2>&1; then
            echo "⏳" "TESTING" "npm/vitest running"; return; fi
        if pgrep -f "npm install\|pip install\|yarn install\|pnpm install" >/dev/null 2>&1; then
            echo "📥" "INSTALLING" "dependency install"; return; fi
        if pgrep -f "tsc\b\|vite build\|webpack" >/dev/null 2>&1; then
            echo "🔨" "COMPILING" "TypeScript/bundler"; return; fi
        if pgrep -f "eslint\|ktlint\|prettier" >/dev/null 2>&1; then
            echo "🔍" "LINTING" "code analysis"; return; fi
        if pgrep -f "git commit\|git push\|git add" >/dev/null 2>&1; then
            echo "📦" "GIT" "committing changes"; return; fi

        if (( output_age < 30 )); then echo "🔄" "CODING" "active output"; return; fi
        if project_files_changing "$PROJECT_DIR" 30; then
            echo "✏️ " "WRITING" "modifying source files"; return; fi
        if (( output_age < 300 )); then
            echo "🧠" "THINKING" "no output for $(fmt_dur "$output_age")"; return; fi
        if (( output_age < 1200 )); then
            echo "⚠️ " "LONG WAIT" "no output for $(fmt_dur "$output_age")"; return; fi
        echo "🔴" "LIKELY STUCK" "Claude alive but silent $(fmt_dur "$output_age")"
        return
    fi

    if (( output_age < 60 )); then
        echo "🔄" "BETWEEN SESSIONS" "preparing next session"; return; fi
    if [[ -f "$HARNESS_LOG" ]] && tail -3 "$HARNESS_LOG" 2>/dev/null | grep -q "rate limited\|Waiting.*retry\|error.*exit"; then
        echo "⏸️ " "RATE LIMITED" "backoff wait"; return; fi
    if (( output_age < 300 )); then
        echo "🟡" "SESSION GAP" "$(fmt_dur "$output_age") since last activity"; return; fi
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

    read -r state_icon state_label state_detail <<< "$(detect_state "$output_age")"

    # ── Header ──
    echo -e "${BOLD}${C}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${C}║${NC}  ${BOLD}Harness Monitor${NC}                           ${DIM}$(date '+%H:%M:%S')${NC}  ${BOLD}${C}║${NC}"
    echo -e "${BOLD}${C}╚════════════════════════════════════════════════════════════════╝${NC}"

    # ── Status Line ──
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

    # ── Current Activity (C: state file) ──
    if [[ -f "$STATE_FILE" ]]; then
        st_age=$(get_file_age "$STATE_FILE")
        if (( st_age < 120 )); then
            st_thinking=$(jq -r '.thinking // ""' "$STATE_FILE" 2>/dev/null || true)
            st_tool=$(jq -r '.tool // ""' "$STATE_FILE" 2>/dev/null || true)
            st_detail=$(jq -r '.detail // ""' "$STATE_FILE" 2>/dev/null || true)
            st_result=$(jq -r '.result // ""' "$STATE_FILE" 2>/dev/null || true)
            st_error=$(jq -r '.error // "false"' "$STATE_FILE" 2>/dev/null || true)

            echo -e "  ${BOLD}Now${NC}  ${DIM}(${st_age}s ago)${NC}"
            if [[ -n "$st_thinking" && "$st_thinking" != "null" ]]; then
                echo -e "    ${M}🧠 ${st_thinking:0:75}${NC}"
            fi
            if [[ -n "$st_tool" && "$st_tool" != "null" ]]; then
                if [[ -n "$st_detail" && "$st_detail" != "null" ]]; then
                    echo -e "    ${Y}⚡ ${st_tool}${NC} ${DIM}${st_detail:0:55}${NC}"
                else
                    echo -e "    ${Y}⚡ ${st_tool}${NC}"
                fi
            fi
            if [[ -n "$st_result" && "$st_result" != "null" ]]; then
                if [[ "$st_error" == "true" ]]; then
                    echo -e "    ${R}✗ ${st_result:0:70}${NC}"
                else
                    echo -e "    ${G}→ ${st_result:0:70}${NC}"
                fi
            fi
            echo ""
        fi
    fi

    # ── Raw Stream Tail (B: direct tmpfile) ──
    if [[ -f "$TMPFILE_PTR" ]]; then
        raw_tmpfile=$(cat "$TMPFILE_PTR" 2>/dev/null || true)
        if [[ -n "$raw_tmpfile" && -f "$raw_tmpfile" ]]; then
            raw_age=$(get_file_age "$raw_tmpfile")
            raw_lines=$(tail -3 "$raw_tmpfile" 2>/dev/null | \
                jq -r '
                    if .type == "assistant" then
                        ([.message.content[]? | select(.type == "tool_use") |
                            .name as $n |
                            if $n == "Bash" then ("$ " + (.input.command // "" | .[0:80]))
                            elif $n == "Read" then ("📖 " + (.input.file_path // ""))
                            elif $n == "Edit" then ("✏️  " + (.input.file_path // ""))
                            elif $n == "Write" then ("📝 " + (.input.file_path // ""))
                            elif $n == "Grep" then ("🔍 " + (.input.pattern // "") + " in " + (.input.path // "."))
                            elif $n == "Glob" then ("📂 " + (.input.pattern // ""))
                            elif $n == "Task" then ("🤖 " + (.input.description // ""))
                            else $n end
                        ] | join("\n"))
                    elif .type == "user" then
                        ([.message.content[]? | select(.type == "tool_result") |
                            (.content // "" | tostring | .[0:80])
                        ] | join("\n") | if . == "" then empty else "  → " + . end)
                    else empty end
                ' 2>/dev/null || true)
            if [[ -n "$raw_lines" ]]; then
                echo -e "  ${BOLD}Live${NC}  ${DIM}(stream ${raw_age}s ago)${NC}"
                echo "$raw_lines" | tail -4 | while IFS= read -r rl; do
                    echo -e "    ${DIM}${rl:0:68}${NC}"
                done
                echo ""
            fi
        fi
    fi

    # ── Current Feature ──
    if [[ -f "$FEATURES_FILE" ]]; then
        current_feat=$(jq -r '
            [.features[] | select(.passes == false)]
            | sort_by(.priority // 999, .id)
            | .[0]
            | "\(.id): \(.description // .name // "unknown")[0:60]"
        ' "$FEATURES_FILE" 2>/dev/null || echo "")
        if [[ -n "$current_feat" && "$current_feat" != "null" ]]; then
            echo -e "  ${BOLD}Target${NC}  ${Y}${current_feat:0:62}${NC}"
        fi
    fi

    # ── Process Tree ──
    child_procs=""
    if [[ -n "${claude_pid:-}" && "$claude_pid" != "" ]]; then
        child_procs=$(ps -o pid=,command= -g "$(ps -o pgid= -p "$claude_pid" 2>/dev/null | tr -d ' ')" 2>/dev/null | \
            grep -v "claude\|tail\|bash.*harness\|ps " | \
            sed 's/^ *//' | head -3 || true)
    fi
    if [[ -n "$child_procs" ]]; then
        echo -e "  ${BOLD}Procs${NC}   ${DIM}$(echo "$child_procs" | head -1 | cut -c1-60)${NC}"
        echo "$child_procs" | tail -n +2 | while IFS= read -r p; do
            echo -e "          ${DIM}${p:0:60}${NC}"
        done
    fi
    echo ""

    # ── Token Usage + Rate ──
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

        # Token rate (tokens per minute) — based on live log file age
        log_age=$(get_file_age "$LIVE_LOG")
        log_created=$(stat -f %B "$LIVE_LOG" 2>/dev/null || stat -c %W "$LIVE_LOG" 2>/dev/null || echo 0)
        now_ts=$(date +%s)
        if [[ "$log_created" -gt 0 ]]; then
            session_elapsed=$(( now_ts - log_created ))
        else
            session_elapsed=1
        fi
        if (( session_elapsed > 0 )); then
            tok_per_min=$(( live_total * 60 / session_elapsed ))
        else
            tok_per_min=0
        fi

        echo -e "    Session:  ${C}↓$(fmt_tokens "$live_in")${NC} in  ${Y}↑$(fmt_tokens "$live_out")${NC} out  ${W}Σ$(fmt_tokens "$live_total")${NC}  ${DIM}(\$${session_cost})${NC}"
        echo -e "    Rate:     ${W}$(fmt_tokens "$tok_per_min")${NC}${DIM}/min${NC}  ${DIM}${live_ev} events  $(fmt_dur "$session_elapsed") elapsed${NC}"
    else
        echo -e "    Session:  ${DIM}(no live data)${NC}"
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

    # ── Git Activity ──
    echo -e "${BOLD}  Git${NC}"
    commits=$(git -C "$PROJECT_DIR" rev-list --count HEAD 2>/dev/null || echo 0)
    last_msg=$(git -C "$PROJECT_DIR" log --format='%s' -1 2>/dev/null || echo "—")
    diff_stat=$(git -C "$PROJECT_DIR" diff --shortstat HEAD 2>/dev/null || echo "")
    unstaged=$(git -C "$PROJECT_DIR" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    unstaged=${unstaged:-0}
    echo -e "    ${DIM}commits:${NC}${W}${commits}${NC}  ${DIM}unstaged:${NC}${Y}${unstaged}${NC}  ${DIM}${diff_stat}${NC}"
    echo -e "    ${DIM}last: ${last_msg:0:58}${NC}"

    # Recently modified source files (last 60s)
    recent_files=$(find "$PROJECT_DIR/app/src" "$PROJECT_DIR/src" "$PROJECT_DIR/lib" \
        -type f \( -name "*.kt" -o -name "*.ts" -o -name "*.java" -o -name "*.py" -o -name "*.js" \) \
        -mmin -1 2>/dev/null | head -5 || true)
    if [[ -n "$recent_files" ]]; then
        echo -e "    ${BOLD}Recently modified:${NC}"
        echo "$recent_files" | while IFS= read -r f; do
            fname=$(basename "$f")
            fdir=$(dirname "$f" | sed "s|$PROJECT_DIR/||")
            echo -e "      ${G}●${NC} ${DIM}${fdir}/${NC}${W}${fname}${NC}"
        done
    fi
    echo ""

    # ── Stream + Actions ──
    if [[ -f "$LIVE_LOG" && -s "$LIVE_LOG" ]]; then
        total_events=$(wc -l < "$LIVE_LOG" 2>/dev/null | tr -d ' ')
        total_events=${total_events:-0}
        tool_count=$(jq -r 'select(.tools != null and .tools != "") | .tools' "$LIVE_LOG" 2>/dev/null | wc -l | tr -d ' ')
        tool_count=${tool_count:-0}
        think_count=$(jq -r 'select(.thinking != null and .thinking != "") | .thinking' "$LIVE_LOG" 2>/dev/null | wc -l | tr -d ' ')
        think_count=${think_count:-0}

        live_age=$(get_file_age "$LIVE_LOG")
        if (( live_age < 10 )); then
            stream_status="${G}● FLOWING${NC}"
        elif (( live_age < 60 )); then
            stream_status="${G}● active ${DIM}(${live_age}s ago)${NC}"
        elif (( live_age < 300 )); then
            stream_status="${Y}⚠ slow ${DIM}($(fmt_dur "$live_age"))${NC}"
        else
            stream_status="${R}✗ stale ${DIM}($(fmt_dur "$live_age"))${NC}"
        fi

        echo -e "${BOLD}  Stream${NC}  ${stream_status}  ${DIM}events:${NC}${W}${total_events}${NC} ${DIM}tools:${NC}${C}${tool_count}${NC} ${DIM}thinks:${NC}${M}${think_count}${NC}"
        echo ""

        echo -e "${BOLD}  Actions${NC}"
        jq -r '
            if .thinking != null and .thinking != "" then
                "\(.ts) \u001b[2;35m🧠 \(.thinking[:80])\u001b[0m"
            elif .detail != null and .detail != "" then
                "\(.ts) \u001b[1;33m⚡ \(.detail[:75])\u001b[0m"
            elif .tools != null and .tools != "" then
                "\(.ts) \u001b[1;33m⚡ \(.tools)\u001b[0m"
            elif .type == "tool_result" then
                if .error == "true" then
                    "\(.ts) \u001b[0;31m✗ \(.result[:60])\u001b[0m"
                else
                    "\(.ts) \u001b[2m→ \(.result[:60])\u001b[0m"
                end
            elif .text != null and .text != "" then
                "\(.ts) \u001b[0;34m💬 \(.text[:70])\u001b[0m"
            elif .type == "result" then
                if .is_error == true then
                    "\(.ts) \u001b[0;31m✗ Error (in:\(.input_tokens) out:\(.output_tokens))\u001b[0m"
                else
                    "\(.ts) \u001b[0;32m✓ Done (in:\(.input_tokens) out:\(.output_tokens))\u001b[0m"
                end
            else empty end
        ' "$LIVE_LOG" 2>/dev/null | tail -14 | while IFS= read -r line; do
            echo -e "    $line"
        done
    else
        echo -e "${BOLD}  Stream${NC}  ${DIM}(no live data)${NC}"
        echo ""
        echo -e "${BOLD}  Actions${NC}"
        if [[ -n "$OUTPUT_FILE" && -f "$OUTPUT_FILE" ]]; then
            tail -15 "$OUTPUT_FILE" 2>/dev/null | \
                sed 's/\x1b\[[0-9;]*m//g' | grep -v '^$' | tail -8 | \
                while IFS= read -r line; do echo -e "    ${DIM}${line:0:65}${NC}"; done
        else
            echo -e "    ${DIM}(no data)${NC}"
        fi
    fi
    echo ""

    # ── Session History (compact) ──
    if [[ -f "$HARNESS_LOG" ]] && grep -q "^--- Session" "$HARNESS_LOG" 2>/dev/null; then
        echo -e "${BOLD}  History${NC}"
        paste <(grep "^--- Session" "$HARNESS_LOG" 2>/dev/null | sed 's/--- Session \([0-9]*\).*/S\1/') \
              <(grep "^Duration:" "$HARNESS_LOG" 2>/dev/null | awk '{print $2}') \
              <(grep "^Features:" "$HARNESS_LOG" 2>/dev/null | awk '{print $2}') \
              2>/dev/null | \
        while IFS=$'\t' read -r sess dur feat; do
            fpass=$(echo "$feat" | cut -d/ -f1)
            ftot=$(echo "$feat" | cut -d/ -f2)
            if [[ "$fpass" == "$ftot" ]] && [[ "$fpass" != "0" ]]; then
                icon="${G}✓${NC}"
            elif [[ "$fpass" != "0" ]]; then
                icon="${Y}◐${NC}"
            else
                icon="${R}○${NC}"
            fi
            printf "    ${icon} %-4s  %6s  %s\n" "$sess" "$dur" "$feat"
        done | tail -8
        echo ""
    fi

    # ── Bottom Bar ──
    model=$(grep "^Model:" "$HARNESS_LOG" 2>/dev/null | head -1 | awk '{print $2}')
    out_id=$(basename "${OUTPUT_FILE:-none}" .output)
    if [[ -n "$OUTPUT_FILE" && -f "$OUTPUT_FILE" ]]; then
        file_age=$(get_file_age "$OUTPUT_FILE")
        if (( file_age < 30 )); then out_status="${G}● ACTIVE${NC}"
        elif (( file_age < 120 )); then out_status="${G}● $(fmt_dur "$file_age")${NC}"
        elif (( file_age < 300 )); then out_status="${Y}⚠ SLOW $(fmt_dur "$file_age")${NC}"
        else out_status="${R}✗ STALE $(fmt_dur "$file_age")${NC}"
        fi
    else
        out_status="${DIM}no output${NC}"
    fi

    echo -e "${DIM}  ──────────────────────────────────────────────────────────────${NC}"
    echo -e "  ${DIM}model:${NC}${C}${model:-?}${NC} ${DIM}output:${NC}${out_status} ${DIM}id:${NC}${DIM}${out_id:0:8}${NC}"

    # ── Animated Countdown ──
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
