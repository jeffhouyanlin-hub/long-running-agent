#!/usr/bin/env bash
# harness.sh — Main orchestrator for the long-running agent system
#
# Runs Claude in a loop: first an initializer session to set up the project,
# then repeated coding sessions until all features pass or max sessions reached.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/utils.sh"

# ─── Defaults ───────────────────────────────────────────────────────────────

PROJECT_DIR="./project"
MAX_SESSIONS=50
MODEL="sonnet"
MCP_CONFIG=""
SKIP_INIT=false
DRY_RUN=false
GOAL=""

# ─── Usage ──────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] "project goal description"

Orchestrates Claude across multiple sessions to build a project incrementally.

Options:
  -d, --dir <path>        Working directory for the project (default: ./project)
  -m, --max-sessions <n>  Maximum number of coding sessions (default: 50)
  -M, --model <model>     Claude model to use (default: sonnet)
  --mcp-config <path>     MCP config file to pass to Claude
  --skip-init             Skip initializer, resume from existing artifacts
  --dry-run               Show what would be executed without running
  -h, --help              Show this help message

Examples:
  $(basename "$0") "Build a REST API for a todo app with Node.js and Express"
  $(basename "$0") -d ./my-app -m 30 "Build a CLI markdown-to-HTML converter in Python"
  $(basename "$0") --skip-init -d ./my-app "Continue building the app"
EOF
    exit 0
}

# ─── Argument Parsing ───────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--dir)
            PROJECT_DIR="$2"
            shift 2
            ;;
        -m|--max-sessions)
            MAX_SESSIONS="$2"
            shift 2
            ;;
        -M|--model)
            MODEL="$2"
            shift 2
            ;;
        --mcp-config)
            MCP_CONFIG="$2"
            shift 2
            ;;
        --skip-init)
            SKIP_INIT=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        -*)
            log_error "Unknown option: $1"
            echo "Use --help for usage information."
            exit 1
            ;;
        *)
            if [[ -z "$GOAL" ]]; then
                GOAL="$1"
            else
                log_error "Unexpected argument: $1"
                echo "Goal already set to: $GOAL"
                exit 1
            fi
            shift
            ;;
    esac
done

if [[ -z "$GOAL" ]]; then
    log_error "No project goal provided."
    echo "Use --help for usage information."
    exit 1
fi

# ─── Clear Nesting Guard ────────────────────────────────────────────────────
# When harness.sh is launched from within a Claude Code session, the CLAUDECODE
# env var is inherited and blocks nested `claude` invocations. Unset it so
# the harness can spawn its own independent Claude sessions.
unset CLAUDECODE 2>/dev/null || true

# ─── Validate Environment ──────────────────────────────────────────────────

if ! command -v claude &>/dev/null; then
    log_error "Claude CLI not found. Install it first: https://docs.anthropic.com/en/docs/claude-code"
    exit 1
fi

if ! command -v jq &>/dev/null; then
    log_error "jq not found. Install it: brew install jq (macOS) or apt install jq (Linux)"
    exit 1
fi

# ─── Resolve Paths ──────────────────────────────────────────────────────────

PROJECT_DIR="$(cd "$(dirname "$PROJECT_DIR")" 2>/dev/null && pwd)/$(basename "$PROJECT_DIR")" || {
    # Parent doesn't exist yet, that's OK — we'll create it
    PROJECT_DIR="$(pwd)/$PROJECT_DIR"
}
HARNESS_LOG="$PROJECT_DIR/harness-log.txt"
FEATURES_FILE="$PROJECT_DIR/features.json"

# ─── Prepare Prompt Files ──────────────────────────────────────────────────

# Render a prompt template by replacing placeholders
render_prompt() {
    local template_file="$1"
    local output
    output=$(cat "$template_file")
    output="${output//\{\{GOAL\}\}/$GOAL}"
    output="${output//\{\{PROJECT_DIR\}\}/$PROJECT_DIR}"
    echo "$output"
}

# ─── Dry Run ────────────────────────────────────────────────────────────────

if [[ "$DRY_RUN" == true ]]; then
    log_header "DRY RUN"
    echo "Goal:           $GOAL"
    echo "Project dir:    $PROJECT_DIR"
    echo "Max sessions:   $MAX_SESSIONS"
    echo "Model:          $MODEL"
    echo "MCP config:     ${MCP_CONFIG:-none}"
    echo "Skip init:      $SKIP_INIT"
    echo ""

    if [[ "$SKIP_INIT" == false ]]; then
        echo "Step 1: Would run initializer session"
        echo "  Prompt: $SCRIPT_DIR/prompts/initializer.md"
        echo "  Creates: init.sh, features.json, claude-progress.txt, .git/"
        echo ""
    fi

    echo "Step 2: Would loop up to $MAX_SESSIONS coding sessions"
    echo "  Prompt: $SCRIPT_DIR/prompts/coding.md"
    echo "  Each session: pick 1 feature → implement → test → update artifacts → commit"
    echo ""

    echo "Claude command that would be used:"
    echo "  claude -p <prompt> --model $MODEL --output-format stream-json --dangerously-skip-permissions"
    if [[ -n "$MCP_CONFIG" ]]; then
        echo "  --mcp-config $MCP_CONFIG"
    fi

    exit 0
fi

# ─── Create Project Directory ──────────────────────────────────────────────

mkdir -p "$PROJECT_DIR"

log_header "Long-Running Agent Harness"
echo "Goal:         $GOAL"
echo "Project dir:  $PROJECT_DIR"
echo "Max sessions: $MAX_SESSIONS"
echo "Model:        $MODEL"
echo ""

# Initialize harness log
echo "=== Harness Log ===" > "$HARNESS_LOG"
echo "Goal: $GOAL" >> "$HARNESS_LOG"
echo "Started: $(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$HARNESS_LOG"
echo "Model: $MODEL" >> "$HARNESS_LOG"

# ─── Build Extra Args ──────────────────────────────────────────────────────

EXTRA_ARGS=()
if [[ -n "$MCP_CONFIG" ]]; then
    EXTRA_ARGS+=(--mcp-config "$MCP_CONFIG")
fi

# ─── Phase 1: Initializer ──────────────────────────────────────────────────

if [[ "$SKIP_INIT" == false ]]; then
    log_header "Phase 1: Initializer Session"

    if validate_artifacts "$PROJECT_DIR" 2>/dev/null; then
        log_warn "Artifacts already exist in $PROJECT_DIR"
        log_warn "Use --skip-init to resume, or remove the directory to start fresh."
        exit 1
    fi

    # Render the initializer prompt
    INIT_PROMPT_FILE=$(mktemp)
    render_prompt "$SCRIPT_DIR/prompts/initializer.md" > "$INIT_PROMPT_FILE"

    INIT_START=$(date +%s)

    log_info "Starting initializer session..."
    init_exit=0
    run_claude_session "$INIT_PROMPT_FILE" "$PROJECT_DIR" "$MODEL" ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} || init_exit=$?
    rm -f "$INIT_PROMPT_FILE"

    INIT_END=$(date +%s)
    INIT_DURATION=$(( INIT_END - INIT_START ))

    if [[ $init_exit -ne 0 ]]; then
        log_error "Initializer session failed (exit code: $init_exit)"
        log_session "$HARNESS_LOG" 0 0 0 "$INIT_DURATION" "$init_exit"
        exit 1
    fi

    # Validate that artifacts were created
    if ! validate_artifacts "$PROJECT_DIR"; then
        log_error "Initializer session completed but artifacts are missing."
        log_error "Expected: init.sh, features.json, claude-progress.txt, .git/"
        exit 1
    fi

    # Check initial feature count
    read -r passed total <<< "$(check_features_progress "$FEATURES_FILE")"
    log_success "Initializer complete. Features: $passed/$total $(progress_bar "$passed" "$total")"
    log_session "$HARNESS_LOG" 0 "$passed" "$total" "$INIT_DURATION" 0

else
    log_info "Skipping initializer (--skip-init)"
    if ! validate_artifacts "$PROJECT_DIR"; then
        log_error "Cannot skip init: artifacts are missing in $PROJECT_DIR"
        exit 1
    fi
    read -r passed total <<< "$(check_features_progress "$FEATURES_FILE")"
    log_info "Resuming with $passed/$total features passing"
fi

# ─── Phase 2: Coding Loop ──────────────────────────────────────────────────

log_header "Phase 2: Coding Sessions"

SESSION=1
CONSECUTIVE_FAILURES=0
MAX_CONSECUTIVE_FAILURES=5
BACKOFF_BASE=30  # seconds

while [[ $SESSION -le $MAX_SESSIONS ]]; do
    # Check progress before starting
    read -r passed total <<< "$(check_features_progress "$FEATURES_FILE")"

    if [[ "$total" -gt 0 && "$passed" -ge "$total" ]]; then
        log_header "ALL FEATURES PASSING!"
        log_success "All $total features are passing after $((SESSION - 1)) coding sessions."
        echo "completed" >> "$HARNESS_LOG"
        break
    fi

    remaining=$(( total - passed ))
    log_header "Coding Session $SESSION / $MAX_SESSIONS"
    echo "Progress: $(progress_bar "$passed" "$total")  ($remaining remaining)"
    echo ""

    # Render the coding prompt
    CODING_PROMPT_FILE=$(mktemp)
    render_prompt "$SCRIPT_DIR/prompts/coding.md" > "$CODING_PROMPT_FILE"

    SESSION_START=$(date +%s)

    session_exit=0
    run_claude_session "$CODING_PROMPT_FILE" "$PROJECT_DIR" "$MODEL" ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} || session_exit=$?
    rm -f "$CODING_PROMPT_FILE"

    SESSION_END=$(date +%s)
    SESSION_DURATION=$(( SESSION_END - SESSION_START ))

    # Re-read progress after session
    read -r passed total <<< "$(check_features_progress "$FEATURES_FILE")"

    if [[ $session_exit -ne 0 ]]; then
        log_warn "Session $SESSION exited with code $session_exit (duration: ${SESSION_DURATION}s)"
        CONSECUTIVE_FAILURES=$(( CONSECUTIVE_FAILURES + 1 ))

        # If session failed very quickly (<10s), it's likely a rate limit or API error
        if [[ $SESSION_DURATION -lt 10 ]]; then
            wait_time=$(( BACKOFF_BASE * CONSECUTIVE_FAILURES ))
            if [[ $wait_time -gt 300 ]]; then
                wait_time=300  # cap at 5 minutes
            fi
            log_warn "Session failed in <10s — likely rate limited. Waiting ${wait_time}s before retry..."
            sleep "$wait_time"
        fi

        # Bail out after too many consecutive failures
        if [[ $CONSECUTIVE_FAILURES -ge $MAX_CONSECUTIVE_FAILURES ]]; then
            log_error "$MAX_CONSECUTIVE_FAILURES consecutive failures. Stopping to avoid wasting sessions."
            log_error "Check API rate limits or errors, then resume with --skip-init."
            log_session "$HARNESS_LOG" "$SESSION" "$passed" "$total" "$SESSION_DURATION" "$session_exit"
            break
        fi
    else
        CONSECUTIVE_FAILURES=0
    fi

    log_info "Session $SESSION complete in ${SESSION_DURATION}s. Features: $passed/$total $(progress_bar "$passed" "$total")"
    log_session "$HARNESS_LOG" "$SESSION" "$passed" "$total" "$SESSION_DURATION" "$session_exit"

    SESSION=$(( SESSION + 1 ))
done

# ─── Final Summary ──────────────────────────────────────────────────────────

read -r passed total <<< "$(check_features_progress "$FEATURES_FILE")"

log_header "Final Summary"
echo "Features passing: $passed / $total  $(progress_bar "$passed" "$total")"
echo "Sessions used:    $((SESSION - 1))"
echo "Harness log:      $HARNESS_LOG"
echo "Project dir:      $PROJECT_DIR"

if [[ "$passed" -ge "$total" && "$total" -gt 0 ]]; then
    log_success "Project complete!"
    exit 0
else
    log_warn "Project incomplete. $((total - passed)) features remaining."
    log_warn "Re-run with: $(basename "$0") --skip-init -d \"$PROJECT_DIR\" \"$GOAL\""
    exit 1
fi
