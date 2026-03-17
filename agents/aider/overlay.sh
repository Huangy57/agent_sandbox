# Aider agent overlay
#
# Aider has no instruction file to merge. No-op overlay.

agent_prepare_config() {
    local project_dir="$1"
    # Aider reads config from ~/.aider.conf.yml (read-only in sandbox).
    # No config merging needed.
}

agent_get_env_exports() {
    :
}
