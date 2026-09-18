#!/bin/bash
set -f

input=$(cat)

if [ -z "$input" ]; then
    printf "agy"
    exit 0
fi

# ── Colors ──────────────────────────────────────────────
blue='\033[38;2;0;153;255m'
orange='\033[38;2;255;176;85m'
green='\033[38;2;0;175;80m'
cyan='\033[38;2;86;182;194m'
red='\033[38;2;255;85;85m'
yellow='\033[38;2;230;200;0m'
white='\033[38;2;220;220;220m'
magenta='\033[38;2;180;140;255m'
dim='\033[2m'
reset='\033[0m'

sep=" ${dim}│${reset} "

# ── Helpers ─────────────────────────────────────────────
color_for_pct() {
    local pct_val=$1
    local pct_int
    pct_int=$(echo "$pct_val" | tr -d '%' | awk '{printf "%d", $1}')
    if [ "$pct_int" -ge 90 ]; then printf "%s" "$red"
    elif [ "$pct_int" -ge 70 ]; then printf "%s" "$yellow"
    elif [ "$pct_int" -ge 50 ]; then printf "%s" "$orange"
    else printf "%s" "$green"
    fi
}

build_bar() {
    local pct=$1
    local width=$2
    pct=$(echo "$pct" | tr -d '%')
    [ "$pct" -lt 0 ] 2>/dev/null && pct=0
    [ "$pct" -gt 100 ] 2>/dev/null && pct=100

    local filled=$(( pct * width / 100 ))
    local empty=$(( width - filled ))
    local bar_color
    bar_color=$(color_for_pct "$pct")

    local filled_str="" empty_str=""
    for ((i=0; i<filled; i++)); do filled_str+="●"; done
    for ((i=0; i<empty; i++)); do empty_str+="○"; done

    printf "%b" "${bar_color}${filled_str}${dim}${empty_str}${reset}"
}

format_reset_time() {
    local reset_iso=$1
    local style=$2  # "time" for 5h, "datetime" for 7d
    [ -z "$reset_iso" ] || [ "$reset_iso" = "null" ] && return

    local result=""
    # Primary: try python3 (cross-platform, reliable ISO parse)
    if command -v python3 >/dev/null 2>&1; then
        if [ "$style" = "time" ]; then
            result=$(python3 -c "import sys, datetime; dt = datetime.datetime.fromisoformat(sys.argv[1].replace('Z','+00:00')).astimezone(); print(dt.strftime('%H:%M'))" "$reset_iso" 2>/dev/null)
        else
            result=$(python3 -c "import sys, datetime; dt = datetime.datetime.fromisoformat(sys.argv[1].replace('Z','+00:00')).astimezone(); print(dt.strftime('%b %d, %H:%M').lower())" "$reset_iso" 2>/dev/null)
        fi
    fi

    # Fallback: date -d (GNU date)
    if [ -z "$result" ]; then
        local epoch
        epoch=$(date -d "$reset_iso" +%s 2>/dev/null)
        if [ -n "$epoch" ]; then
            if [ "$style" = "time" ]; then
                result=$(date -d "@$epoch" +"%H:%M" 2>/dev/null)
            else
                result=$(date -d "@$epoch" +"%b %-d, %H:%M" 2>/dev/null | tr '[:upper:]' '[:lower:]')
            fi
        fi
    fi
    printf "%s" "$result"
}

format_tokens() {
    local tokens=$1
    # Strip decimals for bash integer comparison
    tokens="${tokens%.*}"
    if [ -z "$tokens" ]; then tokens=0; fi

    if [ "$tokens" -ge 1048576 ]; then
        echo "$tokens" | awk '{printf "%.1fM", $1/1048576}' | sed 's/\.0M/M/'
    elif [ "$tokens" -ge 1000 ]; then
        echo "$tokens" | awk '{printf "%.0fk", $1/1000}'
    else
        echo "${tokens}"
    fi
}

# ── Extract JSON data ────────────────────────────────────
model_name=$(echo "$input" | jq -r '.model.display_name // "agy"')
cwd=$(echo "$input" | jq -r '.cwd // ""')
[ -z "$cwd" ] || [ "$cwd" = "null" ] && cwd=$(pwd)
dirname=$(basename "$cwd")

agent_state=$(echo "$input" | jq -r '.agent_state // ""')
plan_tier=$(echo "$input" | jq -r '.plan_tier // ""')
terminal_width=$(echo "$input" | jq -r '.terminal_width // 80')

# ── Context Calculation ──────────────────────────────────
# Use official CLI used_percentage to match /context command precisely, with subagent overflow protection
ctx_data=$(echo "$input" | jq -r '
  .context_window as $cw |
  if ($cw == null) then "0|0|0"
  else
    ($cw.context_window_size // 1048576) as $size |
    ($cw.used_percentage // (if $size > 0 then (($cw.total_input_tokens // 0) / $size * 100) else 0 end)) as $official_pct |
    (($official_pct / 100 * $size) | floor) as $official_used |
    
    # If subagents cause cumulative tokens to exceed capacity (>1M), fallback to current_usage
    (if $official_used > $size and $cw.current_usage != null and ($cw.current_usage | length) > 0 then
       (($cw.current_usage.input_tokens // 0) + 
        ($cw.current_usage.output_tokens // 0) + 
        ($cw.current_usage.cache_read_input_tokens // 0) + 
        ($cw.current_usage.cache_creation_input_tokens // 0))
     else
       $official_used
     end) as $used |
     
    (if $size > 0 then ($used / $size * 100) else 0 end) as $calc_pct |
    (if $calc_pct > 100 then 100 else $calc_pct end) as $pct |
    "\($pct)|\($used)|\($size)"
  end
')

raw_ctx_pct=$(echo "$ctx_data" | cut -d'|' -f1 | tr -d '%')
ctx_used_tokens=$(echo "$ctx_data" | cut -d'|' -f2)
ctx_size_tokens=$(echo "$ctx_data" | cut -d'|' -f3)

# Format Context Percentage (1 decimal precision, or integer if whole)
ctx_pct_str=$(echo "$raw_ctx_pct" | awk '{
  if ($1 <= 0) printf "0";
  else if ($1 < 0.1) printf "<0.1";
  else {
    formatted = sprintf("%.1f", $1);
    sub(/\.0$/, "", formatted);
    printf "%s", formatted;
  }
}')

# Int percentage for coloring logic
ctx_pct_int=$(echo "$raw_ctx_pct" | awk '{printf "%d", $1}')

# ── Git info ─────────────────────────────────────────────
git_branch=""
git_dirty=""
if git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git_branch=$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null)
    if [ -n "$(git -C "$cwd" --no-optional-locks status --porcelain 2>/dev/null)" ]; then
        git_dirty="*"
    fi
fi

# ── Agent state icon ─────────────────────────────────────
state_icon=""
case "$agent_state" in
    working|running) state_icon="" ;;
    idle)            state_icon="" ;;
    *)               state_icon="" ;;
esac

# ── LINE 1: Model │ Context % │ Directory (branch) │ Plan ──
ctx_color=$(color_for_pct "$ctx_pct_int")

line1="${blue}${model_name}${reset}"
line1+="${sep}"

# Context display: include token details if terminal width allows
if [ "$ctx_size_tokens" -gt 0 ] && [ "$terminal_width" -ge 90 ]; then
    used_fmt=$(format_tokens "$ctx_used_tokens")
    size_fmt=$(format_tokens "$ctx_size_tokens")
    line1+="${ctx_color}${ctx_pct_str}%${reset} ${dim}(${used_fmt} of ${size_fmt})${reset}"
else
    line1+="${ctx_color}${ctx_pct_str}%${reset}"
fi

line1+="${sep}"
line1+="${state_icon}${cyan}${dirname}${reset}"
if [ -n "$git_branch" ]; then
    line1+=" ${green}(${git_branch}${red}${git_dirty}${green})${reset}"
fi
if [ -n "$plan_tier" ] && [ "$plan_tier" != "null" ]; then
    line1+="${sep}${dim}${plan_tier}${reset}"
fi

# ── Detect model pool (3p = Claude/Anthropic, gemini = Google) ──
model_id=$(echo "$input" | jq -r '.model.id // ""' | tr '[:upper:]' '[:lower:]')
if echo "$model_id" | grep -qiE 'claude|anthropic|3p'; then
    quota_pool="3p"
else
    quota_pool="gemini"
fi

# ── Quota lines (from agy JSON — only active pool) ───────────────
bar_width=10
quota_lines=""

if [ "$quota_pool" = "3p" ]; then
    q5h_key="3p-5h"
    qwk_key="3p-weekly"
    pool_label="claude"
else
    q5h_key="gemini-5h"
    qwk_key="gemini-weekly"
    pool_label="gemini"
fi

# 5h quota
q5h_remaining=$(echo "$input" | jq -r ".quota.\"${q5h_key}\".remaining_fraction // empty")
if [ -n "$q5h_remaining" ]; then
    q5h_pct=$(echo "$q5h_remaining" | awk '{printf "%.0f", (1 - $1) * 100}' | tr -d '%')
    q5h_reset_iso=$(echo "$input" | jq -r ".quota.\"${q5h_key}\".reset_time // empty")
    q5h_bar=$(build_bar "$q5h_pct" "$bar_width")
    q5h_color=$(color_for_pct "$q5h_pct")
    q5h_pct_fmt=$(printf "%3d" "$q5h_pct")
    q5h_reset_fmt=$(format_reset_time "$q5h_reset_iso" "time")

    quota_lines+="${white}${pool_label} 5h${reset} ${q5h_bar} ${q5h_color}${q5h_pct_fmt}%${reset}"
    [ -n "$q5h_reset_fmt" ] && quota_lines+=" ${dim}⟳${reset} ${white}${q5h_reset_fmt}${reset}"
fi

# weekly quota
qwk_remaining=$(echo "$input" | jq -r ".quota.\"${qwk_key}\".remaining_fraction // empty")
if [ -n "$qwk_remaining" ]; then
    qwk_pct=$(echo "$qwk_remaining" | awk '{printf "%.0f", (1 - $1) * 100}' | tr -d '%')
    qwk_reset_iso=$(echo "$input" | jq -r ".quota.\"${qwk_key}\".reset_time // empty")
    qwk_bar=$(build_bar "$qwk_pct" "$bar_width")
    qwk_color=$(color_for_pct "$qwk_pct")
    qwk_pct_fmt=$(printf "%3d" "$qwk_pct")
    qwk_reset_fmt=$(format_reset_time "$qwk_reset_iso" "datetime")

    [ -n "$quota_lines" ] && quota_lines+="\n"
    quota_lines+="${white}${pool_label} 7d${reset} ${qwk_bar} ${qwk_color}${qwk_pct_fmt}%${reset}"
    [ -n "$qwk_reset_fmt" ] && quota_lines+=" ${dim}⟳${reset} ${white}${qwk_reset_fmt}${reset}"
fi

# ── Output ───────────────────────────────────────────────
printf "%b" "$line1"
[ -n "$quota_lines" ] && printf "\n\n%b" "$quota_lines"

exit 0
