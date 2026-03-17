# Agent detection for OpenCode
# Returns 0 if OpenCode is installed or configured.

agent_detect() {
    command -v opencode &>/dev/null && return 0
    [[ -d "$HOME/.config/opencode" ]] && return 0
    return 1
}
