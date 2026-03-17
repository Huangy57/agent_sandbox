# Agent detection for Google Gemini CLI
# Returns 0 if Gemini CLI is installed or configured.

agent_detect() {
    command -v gemini &>/dev/null && return 0
    [[ -d "$HOME/.gemini" ]] && return 0
    return 1
}
