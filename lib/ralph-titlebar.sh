#!/bin/zsh
# ralph-titlebar.sh — Terminal title bar (sticky first-line overlay)

_ralph_titlebar_text=""
_ralph_titlebar_active=0

ralph_titlebar_init() {
  local rows
  rows=$(tput lines)
  _ralph_titlebar_active=1
  # Clear screen, move to 1;1, set scroll region 2–bottom, position at line 2
  printf '\033[2J\033[1;1H\033[2K\033[2;%sr\033[2;1H' "$rows" >/dev/tty
  trap 'ralph_titlebar_resize' WINCH
}

ralph_titlebar_resize() {
  local rows cols
  rows=$(tput lines)
  cols=$(tput cols)
  # Update scroll region to new size
  printf '\033[s\033[2;%sr' "$rows" >/dev/tty
  # Redraw the title if we have one
  if [[ -n "$_ralph_titlebar_text" ]]; then
    local text="${_ralph_titlebar_text[1,$cols]}"
    printf '\033[1;1H\033[2K\033[7m%-*s\033[0m' "$cols" "$text" >/dev/tty
  fi
  printf '\033[u' >/dev/tty
  trap 'ralph_titlebar_resize' WINCH
}

ralph_titlebar_update() {
  local text="$1" cols
  _ralph_titlebar_text="$text"
  cols=$(tput cols)
  text="${text[1,$cols]}"
  # Save cursor, move to 1;1, write full-width inverse bar, restore cursor
  printf '\033[s\033[1;1H\033[2K\033[7m%-*s\033[0m\033[u' "$cols" "$text" >/dev/tty
}

ralph_titlebar_cleanup() {
  [[ $_ralph_titlebar_active -eq 0 ]] && return
  _ralph_titlebar_text=""
  _ralph_titlebar_active=0
  # Reset scroll region to full screen, clear the title bar line
  printf '\033[r\033[1;1H\033[2K' >/dev/tty
}
