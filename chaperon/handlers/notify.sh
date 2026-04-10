#! /bin/bash --
# chaperon/handlers/notify.sh — Relay notification to outer terminal
#
# Receives a notification request from inside the sandbox and rings the
# bell on the chaperon's stderr, which is connected to the outer
# terminal (the shell where sandbox-exec.sh was launched). If that
# terminal is inside a tmux session with monitor-bell enabled (the
# default), the window/tab is marked until the user views it.
#
# No message content is passed to tmux — the bell is content-free, so
# there is zero injection risk. The message text is only shown inside
# the sandbox's own tmux (by sandbox-notify, before calling this stub).
#
# Request: CHAPERON/1 notify, ARG[0] = message (logged but not displayed)
# Response: always exit 0 (notifications are best-effort)

handle_notify() {
    local project_dir="$1"
    local sandbox_exec="$2"

    # Ring the bell on the outer terminal.  FD 4 is the chaperon's
    # original stderr (duped by sandbox-exec.sh before redirecting
    # stdout/stderr to /dev/null).  It points to the launching shell's
    # terminal.  If the user launched the sandbox from inside tmux and
    # monitor-bell is on, this marks the window/tab in the status bar —
    # persistent until viewed.  Also works without tmux (terminal bell /
    # desktop notification, depending on the terminal emulator).
    printf '\a' >&4

    return 0
}
