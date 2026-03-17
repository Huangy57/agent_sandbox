# Agent detection for OpenAI Codex CLI
# Returns 0 if Codex is installed or configured.

agent_detect() {
    command -v codex &>/dev/null && return 0
    [[ -d "$HOME/.codex" ]] && return 0
    return 1
}
