# Gemini CLI agent overlay
#
# Merges GEMINI.md with sandbox instructions.

agent_prepare_config() {
    local project_dir="$1"
    local gemini_dir="$HOME/.gemini"
    mkdir -p "$gemini_dir"

    # Merge GEMINI.md with sandbox instructions
    local sandbox_snippet="$SANDBOX_DIR/agents/gemini/agent.md"
    local user_gemini_md="$gemini_dir/GEMINI.md"
    local merged_gemini_md="$gemini_dir/.sandbox-GEMINI.md"
    {
        if [[ -f "$user_gemini_md" ]]; then
            cat "$user_gemini_md"
        fi
        if [[ -f "$sandbox_snippet" ]]; then
            echo ""
            cat "$sandbox_snippet"
        fi
    } > "$merged_gemini_md"
}

agent_get_env_exports() {
    :
}
