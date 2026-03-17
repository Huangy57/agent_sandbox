# Agent detection for Claude Code
# Returns 0 if Claude Code is installed or configured.

agent_detect() {
    command -v claude &>/dev/null && return 0
    [[ -d "$HOME/.claude" ]] && return 0
    return 1
}
