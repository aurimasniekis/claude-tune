#!/bin/bash
# Claude Code status line.
#
#   prompt  — mirrors the oh-my-zsh "robbyrussell" theme: ➜  dir git:(branch) ✗
#   usage   — context window, cost, diff churn, rate limits, elapsed time
#
# Wide terminal:   both on one line, usage right after the prompt.
# Narrow terminal: usage wraps to a second line, dropping low-priority
#                  segments until what remains fits.

input=$(cat)

# --- payload ---------------------------------------------------------------
# One field per line; empty values stay as empty lines, so nothing shifts.
# (A tab-separated read would collapse runs of tabs — tab is IFS whitespace.)
F=()
while IFS= read -r __line; do F+=("$__line"); done < <(printf '%s' "$input" | jq -r '
  def n(x): (x // 0);
  [ (.workspace.current_dir // .cwd // ""),
    (.model.display_name // ""),
    (n(.context_window.used_percentage) | round),
    n(.context_window.total_input_tokens),
    n(.context_window.context_window_size),
    n(.cost.total_cost_usd),
    n(.cost.total_lines_added),
    n(.cost.total_lines_removed),
    (if .rate_limits.five_hour then (.rate_limits.five_hour.used_percentage | round) else "" end),
    (.rate_limits.five_hour.resets_at // ""),
    (if .rate_limits.seven_day then (.rate_limits.seven_day.used_percentage | round) else "" end),
    (.rate_limits.seven_day.resets_at // ""),
    (if .fast_mode then "1" else "" end),
    (.effort.level // ""),
    (.agent.name // ""),
    n(.cost.total_duration_ms),
    (if .exceeds_200k_tokens then "1" else "" end)
  ] | .[] | tostring')

cwd=${F[0]}      model=${F[1]}    ctx_pct=${F[2]}
ctx_used=${F[3]} ctx_size=${F[4]} cost=${F[5]}
added=${F[6]}    removed=${F[7]}
rl5=${F[8]}      rl5_at=${F[9]}   rl7=${F[10]} rl7_at=${F[11]}
fast=${F[12]}    effort=${F[13]}  agent_name=${F[14]}
dur_ms=${F[15]}  exceeds=${F[16]}

[ -n "$cwd" ] && cd "$cwd" 2>/dev/null

GREEN_B=$'\033[1;32m'; GREEN=$'\033[0;32m'
CYAN=$'\033[0;36m'
BLUE_B=$'\033[1;34m'; BLUE=$'\033[0;34m'
RED=$'\033[0;31m';    YELLOW=$'\033[0;33m'
MAGENTA=$'\033[0;35m'; GREY=$'\033[0;90m'
RESET=$'\033[0m'

BAR_W=8

# --- helpers ---------------------------------------------------------------
humanize() { # token count -> 12k / 1.2M / 1M
  local n=$1
  if   [ "$n" -ge 1000000 ]; then awk -v n="$n" 'BEGIN{s=sprintf("%.1f", n/1000000); sub(/\.0$/, "", s); printf "%sM", s}'
  elif [ "$n" -ge 1000 ];    then awk -v n="$n" 'BEGIN{printf "%.0fk", n/1000}'
  else printf '%s' "$n"; fi
}

pct_color() { # 0-100 -> green / yellow / red
  if   [ "$1" -ge 80 ]; then printf '%s' "$RED"
  elif [ "$1" -ge 50 ]; then printf '%s' "$YELLOW"
  else printf '%s' "$GREEN"; fi
}

bar() { # pct -> ▰▰▰▱▱▱▱▱  (always BAR_W cells wide)
  local pct=$1 filled i out=""
  filled=$(( (pct * BAR_W + 50) / 100 ))
  [ "$filled" -gt "$BAR_W" ] && filled=$BAR_W
  for ((i = 0; i < BAR_W; i++)); do
    if [ "$i" -lt "$filled" ]; then out+="▰"; else out+="▱"; fi
  done
  printf '%s' "$out"
}

fmt_dur() { # seconds -> 2d3h / 3h12m / 41m
  local left=$1
  [ "$left" -le 0 ] && { printf 'now'; return; }
  local d=$(( left / 86400 )) h=$(( left / 3600 )) m=$(( (left % 3600) / 60 ))
  if   [ "$d" -ge 1 ]; then printf '%dd%dh' "$d" "$(( (left % 86400) / 3600 ))"
  elif [ "$h" -ge 1 ]; then printf '%dh%02dm' "$h" "$m"
  else printf '%dm' "$m"; fi
}

until_reset() { fmt_dur $(( $1 - $(date +%s) )); }

# Display width is tracked with an ASCII twin of every string: each non-ASCII
# glyph is stood in for by as many '#' as columns it occupies. That keeps the
# arithmetic exact regardless of locale or how bash counts multibyte strings.
GW_ARROW="#"     # ➜
GW_CROSS="#"     # ✗
GW_BOLT="##"     # ⚡ renders double-width
GW_DOT="#"       # ·
GW_RESET="#"     # ↻
GW_BAR="########"

# --- prompt ----------------------------------------------------------------
dir="${PWD/#$HOME/~}"
[ "$dir" != "~" ] && dir="${dir##*/}"

l1="${GREEN_B}➜${RESET}  ${CYAN}${dir}${RESET}"
p1="${GW_ARROW}  ${dir}"

branch=$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null)
if [ -n "$branch" ]; then
  l1+=" ${BLUE_B}git:(${RED}${branch}${BLUE})${RESET}"
  p1+=" git:(${branch})"
  # --no-optional-locks: don't take index.lock, so we never race Claude's own git commands.
  if [ -n "$(git --no-optional-locks status --porcelain 2>/dev/null)" ]; then
    l1+=" ${YELLOW}✗${RESET}"
    p1+=" ${GW_CROSS}"
  fi
fi

if [ -n "$model" ]; then
  tag="${model% (*context)}"   # "Opus 5.5 (1M context)" -> "Opus 5.5"; ctx shows the size
  [ -n "$effort" ] && [ "$effort" != "medium" ] && tag+=" ${effort}"
  l1+=" ${GREY}[${tag}"
  p1+=" [${tag}"
  if [ -n "$fast" ]; then l1+=" ⚡"; p1+=" ${GW_BOLT}"; fi
  l1+="]${RESET}"
  p1+="]"
fi

if [ -n "$agent_name" ]; then
  l1+=" ${MAGENTA}@${agent_name}${RESET}"
  p1+=" @${agent_name}"
fi

# --- usage segments --------------------------------------------------------
# Parallel arrays: colored text, ASCII twin, and drop priority (higher goes first).
segs=(); segp=(); segq=()
add_seg() { segs+=("$1"); segp+=("$2"); segq+=("$3"); }

if [ "${ctx_size:-0}" -gt 0 ]; then
  c=$(pct_color "$ctx_pct")
  u=$(humanize "$ctx_used"); t=$(humanize "$ctx_size")
  add_seg "${GREY}ctx${RESET} ${c}$(bar "$ctx_pct")${RESET} ${c}${ctx_pct}%${RESET} ${GREY}${u}/${t}${RESET}" \
          "ctx ${GW_BAR} ${ctx_pct}% ${u}/${t}" 1
elif [ -n "$exceeds" ]; then
  add_seg "${RED}ctx >200k${RESET}" "ctx >200k" 1
fi

if awk -v c="$cost" 'BEGIN{exit !(c > 0)}'; then
  v=$(awk -v c="$cost" 'BEGIN{printf "$%.2f", c}')
  add_seg "${GREY}${v}${RESET}" "$v" 4
fi

if [ "${added:-0}" -gt 0 ] || [ "${removed:-0}" -gt 0 ]; then
  add_seg "${GREEN}+${added}${RESET}${GREY}/${RESET}${RED}-${removed}${RESET}" "+${added}/-${removed}" 5
fi

if [ -n "$rl5" ]; then
  c=$(pct_color "$rl5")
  s="${GREY}5h${RESET} ${c}${rl5}%${RESET}"; sp="5h ${rl5}%"
  if [ -n "$rl5_at" ]; then
    r=$(until_reset "${rl5_at%%.*}")
    s+=" ${GREY}↻${r}${RESET}"; sp+=" ${GW_RESET}${r}"
  fi
  add_seg "$s" "$sp" 2
fi

if [ -n "$rl7" ]; then
  c=$(pct_color "$rl7")
  s="${GREY}7d${RESET} ${c}${rl7}%${RESET}"; sp="7d ${rl7}%"
  if [ -n "$rl7_at" ]; then
    r=$(until_reset "${rl7_at%%.*}")
    s+=" ${GREY}↻${r}${RESET}"; sp+=" ${GW_RESET}${r}"
  fi
  add_seg "$s" "$sp" 3
fi

if [ "${dur_ms:-0}" -gt 60000 ]; then
  v=$(fmt_dur $(( dur_ms / 1000 )))
  add_seg "${GREY}${v}${RESET}" "$v" 6
fi

# --- layout ----------------------------------------------------------------
cols=${COLUMNS:-}
[ -z "$cols" ] && cols=$(tput cols 2>/dev/null)
case $cols in ''|*[!0-9]*) cols=100 ;; esac
# COLUMNS is the full terminal width, but Claude Code insets the status row,
# so a line that long gets its right end clipped. Bump this if it still clips.
EDGE=6
avail=$(( cols - EDGE ))

join_segs() { # -> l2 / p2 from the surviving segments
  local i sep_c="${GREY} · ${RESET}" sep_p=" ${GW_DOT} "
  l2=""; p2=""
  for ((i = 0; i < ${#segs[@]}; i++)); do
    [ -z "${segs[$i]}" ] && continue
    if [ -n "$l2" ]; then l2+="$sep_c"; p2+="$sep_p"; fi
    l2+="${segs[$i]}"; p2+="${segp[$i]}"
  done
}

drop_lowest() { # blank out the surviving segment with the highest drop priority
  local i best=-1 bestq=0
  for ((i = 0; i < ${#segs[@]}; i++)); do
    [ -z "${segs[$i]}" ] && continue
    if [ "${segq[$i]}" -gt "$bestq" ]; then bestq=${segq[$i]}; best=$i; fi
  done
  [ "$best" -lt 0 ] && return 1
  segs[$best]=""; segp[$best]=""
  return 0
}

w1=${#p1}
join_segs

if [ -z "$l2" ]; then
  printf '%s' "$l1"
  exit 0
fi

# Same line, usage straight after the prompt — only if everything fits.
if [ $(( w1 + 3 + ${#p2} )) -le "$avail" ]; then
  printf '%s%s%s' "$l1" "${GREY} · ${RESET}" "$l2"
  exit 0
fi

# Otherwise a second line, shedding low-priority segments until it fits.
while [ ${#p2} -gt "$avail" ]; do
  drop_lowest || break
  join_segs
done

printf '%s\n%s' "$l1" "$l2"
