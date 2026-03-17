# Codex agent overlay
#
# Merges AGENTS.md with sandbox instructions for Codex CLI.

agent_prepare_config() {
    local project_dir="$1"
    local codex_dir="$HOME/.codex"
    mkdir -p "$codex_dir"

    # Merge AGENTS.md with sandbox instructions
    local sandbox_snippet="$SANDBOX_DIR/agents/codex/agent.md"
    local user_agents_md="$codex_dir/AGENTS.md"
    local merged_agents_md="$codex_dir/.sandbox-AGENTS.md"
    {
        if [[ -f "$user_agents_md" ]]; then
            cat "$user_agents_md"
        fi
        if [[ -f "$sandbox_snippet" ]]; then
            echo ""
            cat "$sandbox_snippet"
        fi
    } > "$merged_agents_md"
}

agent_get_env_exports() {
    :
}
