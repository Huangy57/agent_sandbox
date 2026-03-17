# Agent detection for Aider
# Returns 0 if Aider is installed or configured.

agent_detect() {
    command -v aider &>/dev/null && return 0
    [[ -f "$HOME/.aider.conf.yml" ]] && return 0
    return 1
}
