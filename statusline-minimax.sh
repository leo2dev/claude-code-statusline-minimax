#!/bin/bash
# Line 1: Model | dir@branch (diff) | dirty_files
# Line 2: tokens (%) | effort | usage →reset | session_duration

set -f  # disable globbing

input=$(cat)

if [ -z "$input" ]; then
    printf "Claude"
    exit 0
fi

# ANSI colors matching oh-my-posh theme
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

# Format number with commas (e.g., 134,938)
format_commas() {
    printf "%'d" "$1"
}

# Return color escape based on usage percentage
# Usage: usage_color <pct>
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
pct_remain=$(( 100 - pct_used ))

used_comma=$(format_commas $current)
remain_comma=$(format_commas $(( size - current )))

# Config directory (respects CLAUDE_CONFIG_DIR override)
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

# ===== Detect CC-Switch provider =====
cc_switch_dir="$HOME/.cc-switch"
cc_switch_settings="$cc_switch_dir/settings.json"
cc_switch_db="$cc_switch_dir/cc-switch.db"

provider_name=""
current_provider_id=""
if [ -f "$cc_switch_settings" ] && [ -f "$cc_switch_db" ]; then
    current_provider_id=$(jq -r '.currentProviderClaude // empty' "$cc_switch_settings" 2>/dev/null)
    if [ -n "$current_provider_id" ]; then
        provider_name=$(sqlite3 "$cc_switch_db" "SELECT name FROM providers WHERE id='$current_provider_id' AND app_type='claude';" 2>/dev/null)
    fi
fi

# ===== Build two-line output =====
line1=""
line1+="${blue}${model_name}${reset}"
# 显示当前 provider 名称
if [ -n "$provider_name" ]; then
    line1+=" ${dim}(${provider_name})${reset}"
fi

# Current working directory
cwd=$(echo "$input" | jq -r '.cwd // empty')
if [ -n "$cwd" ]; then
    display_dir="${cwd##*/}"
    git_branch=$(git -C "${cwd}" rev-parse --abbrev-ref HEAD 2>/dev/null)
    line1+=" ${dim}|${reset} "
    line1+="${cyan}${display_dir}${reset}"
    if [ -n "$git_branch" ]; then
        line1+="${dim}@${reset}${green}${git_branch}${reset}"
        git_stat=$(git -C "${cwd}" diff --numstat 2>/dev/null | awk '{a+=$1; d+=$2} END {if (a+d>0) printf "+%d -%d", a, d}')
        [ -n "$git_stat" ] && line1+=" ${dim}(${reset}${green}${git_stat%% *}${reset} ${red}${git_stat##* }${reset}${dim})${reset}"

        # 未提交文件数（modified + untracked）
        dirty_count=$(git -C "${cwd}" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
        if [ "$dirty_count" -gt 0 ] 2>/dev/null; then
            line1+=" ${dim}|${reset} ${yellow}${dirty_count}${dim}f${reset}"
        fi
    fi
fi

line2=""
line2+="${orange}${used_tokens}/${total_tokens}${reset} ${dim}(${reset}${green}${pct_used}%${reset}${dim})${reset}"
line2+=" ${dim}|${reset} "
case "$effort_level" in
    low)    line2+="${dim}low${reset}" ;;
    medium) line2+="${orange}med${reset}" ;;
    *)      line2+="${green}high${reset}" ;;
esac

# ===== Provider-aware usage =====
proxy_cache_file="/tmp/claude/statusline-proxy-cache.json"
proxy_cache_age=60
mkdir -p /tmp/claude

proxy_needs_refresh=true
proxy_data=""

if [ -f "$proxy_cache_file" ]; then
    proxy_cache_mtime=$(stat -c %Y "$proxy_cache_file" 2>/dev/null || stat -f %m "$proxy_cache_file" 2>/dev/null)
    now=$(date +%s)
    proxy_age=$(( now - proxy_cache_mtime ))
    if [ "$proxy_age" -lt "$proxy_cache_age" ]; then
        proxy_needs_refresh=false
    fi
    proxy_data=$(cat "$proxy_cache_file" 2>/dev/null)
fi

case "$provider_name" in
    Github*)
        if $proxy_needs_refresh; then
            touch "$proxy_cache_file" 2>/dev/null
            proxy_response=$(curl -s --max-time 5 "http://localhost:4141/usage" 2>/dev/null)
            if [ -n "$proxy_response" ] && echo "$proxy_response" | jq -e '.quota_snapshots.premium_interactions' >/dev/null 2>&1; then
                proxy_data="$proxy_response"
                echo "$proxy_response" > "$proxy_cache_file"
            fi
        fi

        if [ -n "$proxy_data" ] && echo "$proxy_data" | jq -e '.quota_snapshots.premium_interactions' >/dev/null 2>&1; then
            pi_total=$(echo "$proxy_data" | jq -r '.quota_snapshots.premium_interactions.entitlement // 0')
            pi_remain=$(echo "$proxy_data" | jq -r '.quota_snapshots.premium_interactions.quota_remaining // 0')
            pi_reset=$(echo "$proxy_data" | jq -r '.quota_reset_date // ""')

            if [ "$pi_total" -gt 0 ] 2>/dev/null; then
                pi_used=$(( pi_total - pi_remain ))
                pi_pct_used=$(( pi_used * 100 / pi_total ))
                pi_color=$(usage_color "$pi_pct_used")

                line2+=" ${dim}|${reset} "
                line2+="${pi_color}${pi_used}/${pi_total}${reset}"
                [ -n "$pi_reset" ] && line2+=" ${dim}→${pi_reset}${reset}"
            fi
        fi
        ;;
    MiniMax*)
        if $proxy_needs_refresh; then
            touch "$proxy_cache_file" 2>/dev/null
            api_key=$(sqlite3 "$cc_switch_db" "SELECT json_extract(settings_config, '\$.env.ANTHROPIC_AUTH_TOKEN') FROM providers WHERE id='$current_provider_id' AND app_type='claude';" 2>/dev/null)
            if [ -n "$api_key" ]; then
                proxy_response=$(curl -s --max-time 5 "https://www.minimaxi.com/v1/api/openplatform/coding_plan/remains" \
                    -H "Authorization: Bearer $api_key" \
                    -H "Content-Type: application/json" 2>/dev/null)
                if [ -n "$proxy_response" ] && echo "$proxy_response" | jq -e '.model_remains' >/dev/null 2>&1; then
                    proxy_data="$proxy_response"
                    echo "$proxy_response" > "$proxy_cache_file"
                fi
            fi
        fi

        if [ -n "$proxy_data" ] && echo "$proxy_data" | jq -e '.model_remains' >/dev/null 2>&1; then
            mm_total=$(echo "$proxy_data" | jq -r '[.model_remains[] | select(.model_name | startswith("MiniMax-M"))][0].current_interval_total_count // 0')
            mm_used=$(echo "$proxy_data" | jq -r '[.model_remains[] | select(.model_name | startswith("MiniMax-M"))][0].current_interval_usage_count // 0')
            mm_remains_ms=$(echo "$proxy_data" | jq -r '[.model_remains[] | select(.model_name | startswith("MiniMax-M"))][0].remains_time // 0')

            if [ "$mm_total" -gt 0 ] 2>/dev/null; then
                mm_remain=$(( mm_total - mm_used ))
                mm_pct_used=$(( mm_used * 100 / mm_total ))
                mm_color=$(usage_color "$mm_pct_used")
                # remains_time 是毫秒，转换为 h:m 格式
                mm_remain_secs=$(( mm_remains_ms / 1000 ))
                mm_h=$(( mm_remain_secs / 3600 ))
                mm_m=$(( (mm_remain_secs % 3600) / 60 ))

                line2+=" ${dim}|${reset} "
                line2+="${mm_color}${mm_used}/${mm_total}${reset}"
                line2+=" ${dim}→${mm_h}h${mm_m}m${reset}"
            fi
        fi
        ;;
    # 其他 provider 暂不显示用量，后续扩展
esac

# ===== 会话时长 =====
session_start_file="/tmp/claude/session-start.txt"
if [ -f "$session_start_file" ]; then
    session_start=$(cat "$session_start_file" 2>/dev/null)
    now_ts=$(date +%s)
    if [ -n "$session_start" ] && [ "$session_start" -gt 0 ] 2>/dev/null; then
        elapsed=$(( now_ts - session_start ))
        if [ "$elapsed" -ge 3600 ]; then
            sess_h=$(( elapsed / 3600 ))
            sess_m=$(( (elapsed % 3600) / 60 ))
            sess_display="${sess_h}h${sess_m}m"
        elif [ "$elapsed" -ge 60 ]; then
            sess_m=$(( elapsed / 60 ))
            sess_display="${sess_m}m"
        else
            sess_display="${elapsed}s"
        fi
        # 超过 30 分钟用黄色提示，超过 1 小时用橙色
        if [ "$elapsed" -ge 3600 ]; then
            sess_color="$orange"
        elif [ "$elapsed" -ge 1800 ]; then
            sess_color="$yellow"
        else
            sess_color="$dim"
        fi
        line2+=" ${dim}|${reset} ${sess_color}${sess_display}${reset}"
    fi
fi

# Output two lines
printf "%b\n%b" "$line1" "$line2"

exit 0
