#!/bin/bash
# Claude Code Status Line - MiniMax Version
# Features: Model | CWD@Branch | Tokens | Effort | MiniMax Usage

set -f

input=$(cat)

if [ -z "$input" ]; then
    printf "Claude"
    exit 0
fi

# ANSI colors
blue='\033[38;2;0;153;255m'
orange='\033[38;2;255;176;85m'
green='\033[38;2;0;160;0m'
cyan='\033[38;2;46;149;153m'
red='\033[38;2;255;85;85m'
yellow='\033[38;2;230;200;0m'
white='\033[38;2;220;220;220m'
dim='\033[2m'
reset='\033[0m'

# Format token counts (e.g., 50k / 200k)
format_tokens() {
    local num=$1
    if [ "$num" -ge 1000000 ]; then
        awk "BEGIN {printf \"%.1fm\", $num / 1000000}"
    elif [ "$num" -ge 1000 ]; then
        awk "BEGIN {printf \"%.0fk\", $num / 1000}"
    else
        printf "%d" "$num"
    fi
}

# Return color based on usage percentage
usage_color() {
    local pct=$1
    if [ "$pct" -ge 90 ]; then echo "$red"
    elif [ "$pct" -ge 70 ]; then echo "$orange"
    elif [ "$pct" -ge 50 ]; then echo "$yellow"
    else echo "$green"
    fi
}

# ===== Extract data from JSON =====
model_name=$(echo "$input" | jq -r '.model.display_name // "Claude"')

# Context window
size=$(echo "$input" | jq -r '.context_window.context_window_size // 200000')
[ "$size" -eq 0 ] 2>/dev/null && size=200000

# Token usage
input_tokens=$(echo "$input" | jq -r '.context_window.current_usage.input_tokens // 0')
cache_create=$(echo "$input" | jq -r '.context_window.current_usage.cache_creation_input_tokens // 0')
cache_read=$(echo "$input" | jq -r '.context_window.current_usage.cache_read_input_tokens // 0')
current=$(( input_tokens + cache_create + cache_read ))

used_tokens=$(format_tokens $current)
total_tokens=$(format_tokens $size)

if [ "$size" -gt 0 ]; then
    pct_used=$(( current * 100 / size ))
else
    pct_used=0
fi

# Config directory
claude_config_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

# Check reasoning effort
settings_path="$claude_config_dir/settings.json"
effort_level="medium"
if [ -n "$CLAUDE_CODE_EFFORT_LEVEL" ]; then
    effort_level="$CLAUDE_CODE_EFFORT_LEVEL"
elif [ -f "$settings_path" ]; then
    effort_val=$(jq -r '.effortLevel // empty' "$settings_path" 2>/dev/null)
    [ -n "$effort_val" ] && effort_level="$effort_val"
fi

# ===== Build output =====
out=""
out+="${blue}${model_name}${reset}"

# Current working directory
cwd=$(echo "$input" | jq -r '.cwd // empty')
if [ -n "$cwd" ]; then
    display_dir="${cwd##*/}"
    git_branch=$(git -C "${cwd}" rev-parse --abbrev-ref HEAD 2>/dev/null)
    out+=" ${dim}|${reset} "
    out+="${cyan}${display_dir}${reset}"
    if [ -n "$git_branch" ]; then
        out+="${dim}@${reset}${green}${git_branch}${reset}"
        git_stat=$(git -C "${cwd}" diff --numstat 2>/dev/null | awk '{a+=$1; d+=$2} END {if (a+d>0) printf "+%d -%d", a, d}')
        [ -n "$git_stat" ] && out+=" ${dim}(${reset}${green}${git_stat%%}^{*}$reset ${red}${git_stat##* }${reset}${dim})${reset}"
    fi
fi

out+=" ${dim}|${reset} "
out+="${orange}${used_tokens}/${total_tokens}${reset} ${dim}(${reset}${green}${pct_used}%${reset}${dim})${reset}"
out+=" ${dim}|${reset} "
case "$effort_level" in
    low)    out+="${dim}low${reset}" ;;
    medium) out+="${orange}med${reset}" ;;
    *)      out+="${green}high${reset}" ;;
esac

# ===== MiniMax API usage =====
mmax_cache_file="/tmp/claude/statusline-mmax-cache.json"
mmax_cache_age=60
mkdir -p /tmp/claude

mmax_needs_refresh=true
mmax_data=""

if [ -f "$mmax_cache_file" ]; then
    mmax_cache_mtime=$(stat -c %Y "$mmax_cache_file" 2>/dev/null || stat -f %m "$mmax_cache_file" 2>/dev/null)
    now=$(date +%s)
    mmax_age=$(( now - mmax_cache_mtime ))
    if [ "$mmax_age" -lt "$mmax_cache_age" ]; then
        mmax_needs_refresh=false
    fi
    mmax_data=$(cat "$mmax_cache_file" 2>/dev/null)
fi

if $mmax_needs_refresh; then
    touch "$mmax_cache_file" 2>/dev/null

    # Get API key from settings.json
    api_key=""
    if [ -f "$claude_config_dir/settings.json" ]; then
        api_key=$(jq -r '.env.ANTHROPIC_AUTH_TOKEN // empty' "$claude_config_dir/settings.json" 2>/dev/null)
    fi

    if [ -z "$api_key" ] && [ -n "$ANTHROPIC_AUTH_TOKEN" ]; then
        api_key="$ANTHROPIC_AUTH_TOKEN"
    fi

    if [ -n "$api_key" ]; then
        mmax_response=$(curl -s --max-time 10 \
            -H "Authorization: Bearer $api_key" \
            -H "Content-Type: application/json" \
            "https://www.minimaxi.com/v1/api/openplatform/coding_plan/remains" 2>/dev/null)
        if [ -n "$mmax_response" ] && echo "$mmax_response" | jq -e '.model_remains[0]' >/dev/null 2>&1; then
            mmax_data="$mmax_response"
            echo "$mmax_response" > "$mmax_cache_file"
        fi
    fi
fi

if [ -n "$mmax_data" ] && echo "$mmax_data" | jq -e '.model_remains[0]' >/dev/null 2>&1; then
    total=$(echo "$mmax_data" | jq -r '.model_remains[0].current_interval_total_count // 0')
    used=$(echo "$mmax_data" | jq -r '.model_remains[0].current_interval_usage_count // 0')
    end_time=$(echo "$mmax_data" | jq -r '.model_remains[0].end_time // 0')

    if [ "$total" -gt 0 ] 2>/dev/null; then
        pct_used=$(( used * 100 / total ))
        mmax_color=$(usage_color "$pct_used")

        # Convert end_time (ms) to hh:mm
        reset_time=""
        if [ "$end_time" -gt 0 ] 2>/dev/null; then
            end_epoch=$(( end_time / 1000 ))
            reset_time=$(date -r "$end_epoch" +"%H:%M" 2>/dev/null || date -d "@$end_epoch" +"%H:%M" 2>/dev/null)
        fi

        out+=" ${dim}|${reset} "
        out+="${mmax_color}${pct_used}%${reset}"
        [ -n "$reset_time" ] && out+=" ${reset_time}${reset}"
    fi
fi

printf "%b" "$out"
exit 0
