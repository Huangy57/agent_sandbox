# OpenCode agent overlay
#
# Minimal overlay — OpenCode config format TBD.

agent_prepare_config() {
    local project_dir="$1"
    local opencode_dir="$HOME/.config/opencode"
    mkdir -p "$opencode_dir"
}

agent_get_env_exports() {
    :
}
