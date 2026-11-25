# Prepare the current bash terminal for recording the demo. Source it, don't run it:
#
#   source renovate-demo/video-shell.sh
#
# * cd to the repo root and set a short "$ " prompt;
# * clear the screen before every command and reprint the command at the top,
#   without its "#s3b"-style label (bash's PS0 prompt);
# * replace this terminal's history with the demo commands from
#   video-history.txt, in order, without touching ~/.bash_history.
#
# Then press Ctrl+R, type #s2a, and run each command with Ctrl+O: bash runs it
# and puts the next demo command at the prompt. Labels follow the scenes in
# VIDEO_SCRIPT.md, so Ctrl+R #s5b jumps straight to Renovate.
# Close the terminal afterwards to get your normal shell back.
# shellcheck shell=bash

cd "$(dirname "${BASH_SOURCE[0]}")/.." || return
HISTFILE=/dev/null
PS1='\[\e[1;32m\]$\[\e[0m\] '
PS0='\e[H\e[2J\e[1;32m$\e[0m $(fc -ln -1 | sed -E "s/^[[:space:]]+//; s/[[:space:]]+#[[:alnum:]._-]+$//")\n'
history -c
history -r renovate-demo/video-history.txt
clear
