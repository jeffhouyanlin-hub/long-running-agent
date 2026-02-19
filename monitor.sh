#!/usr/bin/env bash
# monitor.sh — Real-time harness monitor (zero tokens, pure shell)
#
# Usage:
#   ./monitor.sh /path/to/project              # auto-detect harness output
#   ./monitor.sh /path/to/project /path/to/output.file  # explicit output file
#   ./monitor.sh                                # defaults to ./project

set -euo pipefail

# ─── Config ─────────────────────────────────────────────────────────────────

REFRESH=3          # seconds between refreshes
STALL_WARN=120     # warn after 2 min no output
STALL_CRIT=300     # critical after 5 min no output

# ─── Colors ─────────────────────────────────────────────────────────────────

R='\033[0;31m'   G='\033[0;32m'   Y='\033[1;33m'
B='\033[0;34m'   C='\033[0;36m'   W='\033[1;37m'
DIM='\033[2m'    BOLD='\033[1m'   NC='\033[0m'
BG_R='\033[41m'  BG_G='\033[42m'  BG_Y='\033[43m'

# ─── Args ───────────────────────────────────────────────────────────────────

PROJECT_DIR="${1:-./project}"
OUTPUT_FILE="${2:-}"

if [[ ! -d "$PROJECT_DIR" ]]; then
    echo -e "${R}Error: Project directory not found: $PROJECT_DIR${NC}"
    exit 1
fi

FEATURES_FILE="$PROJECT_DIR/features.json"
HARNESS_LOG="$PROJECT_DIR/harness-log.txt"
PROGRESS_FILE="$PROJECT_DIR/claude-progress.txt"

# Auto-detect harness output file if not specified
if [[ -z "$OUTPUT_FILE" ]]; then
    # Look in common locations for background task output
    for f in /private/tmp/claude-*/$(whoami)/tasks/*.output /tmp/claude-*/tasks/*.output; do
        if [[ -f "$f" ]]; then
            # Pick the most recently modified one
            if [[ -z "$OUTPUT_FILE" ]] || [[ "$f" -nt "$OUTPUT_FILE" ]]; then
                OUTPUT_FILE="$f"
            fi
        fi
    done
fi

# ─── Helper Functions ───────────────────────────────────────────────────────

get_file_age_seconds() {
    local file="$1"
    if [[ ! -f "$file" ]]; then echo "999999"; return; fi
    local now mod_time
    now=$(date +%s)
    mod_time=$(stat -f %m "$file" 2>/dev/null || stat -c %Y "$file" 2>/dev/null || echo "$now")
    echo $(( now - mod_time ))
}

format_duration() {
    local secs=$1
    if (( secs < 60 )); then
        echo "${secs}s"
    elif (( secs < 3600 )); then
        echo "$((secs/60))m $((secs%60))s"
    else
        echo "$((secs/3600))h $((secs%3600/60))m"
    fi
}

progress_bar() {
    local current=$1 total=$2 width=${3:-30}
    if (( total == 0 )); then echo "[$(printf '%*s' "$width" | tr ' ' '·')]"; return; fi
    local filled=$(( current * width / total ))
    local empty=$(( width - filled ))
    printf '[%s%s]' \
        "$(printf '%*s' "$filled" | tr ' ' '█')" \
        "$(printf '%*s' "$empty" | tr ' ' '·')"
}

stall_indicator() {
    local age=$1
    if (( age > STALL_CRIT )); then
        echo -e "${BG_R}${W} STALLED $(format_duration "$age") ${NC}"
    elif (( age > STALL_WARN )); then
        echo -e "${Y}⚠ SLOW $(format_duration "$age")${NC}"
    else
        echo -e "${G}● ACTIVE${NC}"
    fi
}

# ─── Main Loop ──────────────────────────────────────────────────────────────

trap 'tput cnorm 2>/dev/null; echo ""; exit 0' INT TERM
tput civis 2>/dev/null  # hide cursor

while true; do
    clear

    # ── Header ──
    echo -e "${BOLD}${C}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${C}║${NC}  ${BOLD}🔊 VoxVia Harness Monitor${NC}          ${DIM}$(date '+%H:%M:%S')${NC}  ${BOLD}${C}║${NC}"
    echo -e "${BOLD}${C}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # ── Features Progress ──
    if [[ -f "$FEATURES_FILE" ]]; then
        total=$(jq '[.features[]] | length' "$FEATURES_FILE" 2>/dev/null || echo 0)
        passed=$(jq '[.features[] | select(.passes == true)] | length' "$FEATURES_FILE" 2>/dev/null || echo 0)
        remaining=$(( total - passed ))
        pct=0
        if (( total > 0 )); then pct=$(( passed * 100 / total )); fi

        echo -e "${BOLD}  Features${NC}  $(progress_bar "$passed" "$total")  ${W}${passed}${NC}/${total}  ${G}${pct}%${NC}"

        # Category breakdown
        if (( total > 0 )); then
            echo ""
            echo -e "  ${DIM}Category breakdown:${NC}"
            jq -r '.features[] | "\(.category) \(.passes)"' "$FEATURES_FILE" 2>/dev/null | \
            awk '{
                cats[$1]["total"]++
                if ($2 == "true") cats[$1]["pass"]++
            }
            END {
                for (c in cats) {
                    p = cats[c]["pass"]+0
                    t = cats[c]["total"]
                    if (p == t) mark = "✓"
                    else if (p > 0) mark = "◐"
                    else mark = "○"
                    printf "    %s %-20s %d/%d\n", mark, c, p, t
                }
            }' | sort
        fi
    else
        echo -e "  ${DIM}features.json not yet created...${NC}"
    fi

    echo ""

    # ── Session Status ──
    echo -e "${BOLD}  Session Status${NC}"

    if [[ -f "$HARNESS_LOG" ]]; then
        # Extract latest session info
        last_session=$(grep -c "^--- Session" "$HARNESS_LOG" 2>/dev/null; true)
        last_session=${last_session:-0}
        model=$(grep "^Model:" "$HARNESS_LOG" 2>/dev/null | head -1 | awk '{print $2}')
        started=$(grep "^Started:" "$HARNESS_LOG" 2>/dev/null | head -1 | awk '{print $2}')

        echo -e "    Model:    ${C}${model:-unknown}${NC}"
        echo -e "    Started:  ${started:-unknown}"
        echo -e "    Sessions: ${W}${last_session}${NC} completed"

        # Show last session result
        if (( last_session > 0 )); then
            last_status=$(grep "^Status:" "$HARNESS_LOG" 2>/dev/null | tail -1 | awk '{print $2}')
            last_duration=$(grep "^Duration:" "$HARNESS_LOG" 2>/dev/null | tail -1 | awk '{print $2}')
            last_features=$(grep "^Features:" "$HARNESS_LOG" 2>/dev/null | tail -1 | awk '{print $2}')

            if [[ "$last_status" == "success" ]]; then
                echo -e "    Last:     ${G}${last_status}${NC}  ${last_duration}  ${last_features}"
            else
                echo -e "    Last:     ${R}${last_status}${NC}  ${last_duration}  ${last_features}"
            fi
        fi
    else
        echo -e "    ${DIM}harness-log.txt not yet created...${NC}"
    fi

    echo ""

    # ── Activity / Stall Detection ──
    echo -e "${BOLD}  Activity${NC}"

    # Check harness output file freshness
    if [[ -n "$OUTPUT_FILE" && -f "$OUTPUT_FILE" ]]; then
        output_age=$(get_file_age_seconds "$OUTPUT_FILE")
        echo -e "    Harness output: $(stall_indicator "$output_age")  ${DIM}(last update $(format_duration "$output_age") ago)${NC}"
    else
        echo -e "    Harness output: ${DIM}not found${NC}"
    fi

    # Check features.json freshness
    if [[ -f "$FEATURES_FILE" ]]; then
        feat_age=$(get_file_age_seconds "$FEATURES_FILE")
        echo -e "    features.json:  ${DIM}last modified $(format_duration "$feat_age") ago${NC}"
    fi

    # Check progress file freshness
    if [[ -f "$PROGRESS_FILE" ]]; then
        prog_age=$(get_file_age_seconds "$PROGRESS_FILE")
        echo -e "    progress.txt:   ${DIM}last modified $(format_duration "$prog_age") ago${NC}"
    fi

    # Git commit count
    if [[ -d "$PROJECT_DIR/.git" ]]; then
        commit_count=$(git -C "$PROJECT_DIR" rev-list --count HEAD 2>/dev/null || echo 0)
        last_commit=$(git -C "$PROJECT_DIR" log --oneline -1 2>/dev/null || echo "none")
        echo -e "    Git commits:    ${W}${commit_count}${NC}  ${DIM}latest: ${last_commit}${NC}"
    fi

    echo ""

    # ── Recent Harness Output (last 8 lines) ──
    echo -e "${BOLD}  Recent Output${NC}"
    if [[ -n "$OUTPUT_FILE" && -f "$OUTPUT_FILE" ]]; then
        # Strip ANSI codes and show last 8 meaningful lines
        tail -20 "$OUTPUT_FILE" 2>/dev/null | \
            sed 's/\x1b\[[0-9;]*m//g' | \
            grep -v '^$' | \
            tail -8 | \
            while IFS= read -r line; do
                echo -e "    ${DIM}${line:0:70}${NC}"
            done
    else
        echo -e "    ${DIM}(no output file)${NC}"
    fi

    echo ""

    # ── Token Estimate ──
    echo -e "${BOLD}  Token Estimate${NC}"
    if [[ -f "$HARNESS_LOG" ]]; then
        sessions_done=$(grep -c "^--- Session" "$HARNESS_LOG" 2>/dev/null; true)
        sessions_done=${sessions_done:-0}
        total_duration=0
        while IFS= read -r dur; do
            d=$(echo "$dur" | sed 's/[^0-9]//g')
            total_duration=$(( total_duration + d ))
        done < <(grep "^Duration:" "$HARNESS_LOG" 2>/dev/null | awk '{print $2}')

        # Rough estimate: ~100 tokens/sec for sonnet stream
        est_tokens=$(( total_duration * 80 ))
        # Cost estimate: ~$3/M input + $15/M output for sonnet, rough $0.01/session-sec
        est_cost=$(echo "scale=2; $total_duration * 0.008" | bc 2>/dev/null || echo "?")

        echo -e "    Total compute:  ${W}$(format_duration "$total_duration")${NC} across ${sessions_done} sessions"
        echo -e "    Est. tokens:    ${DIM}~${est_tokens} (rough)${NC}"
        echo -e "    Est. cost:      ${DIM}~\$${est_cost} (rough)${NC}"
    else
        echo -e "    ${DIM}(no data yet)${NC}"
    fi

    echo ""
    echo -e "${DIM}  Refreshing every ${REFRESH}s · Ctrl+C to exit${NC}"

    sleep "$REFRESH"
done
