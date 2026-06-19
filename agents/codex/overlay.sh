# shellcheck shell=bash
# Codex CLI agent overlay
#
# Merges AGENTS.md with sandbox instructions and sets CODEX_HOME
# so Codex reads from the merged directory instead of ~/.codex/ directly.
#
# Called by prepare_agent_configs() in sandbox-lib.sh.

# agent_prepare_config PROJECT_DIR
#   Merges config files and sets up the per-session config directory.
agent_prepare_config() {
    local project_dir="$1"

    # --- Determine the real config directory ---
    # Always use ~/.codex as the base (not CODEX_HOME, which may
    # already point to sandbox-config from a parent sandbox invocation).
    local real_codex_dir="$HOME/.codex"

    local config_dir="$real_codex_dir/sandbox-config"
    chmod u+w "$config_dir" 2>/dev/null || true
    mkdir -p "$config_dir"

    # Codex stores volatile runtime state in SQLite. Sharing those DBs
    # between host Codex and sandboxed Codex is unsafe on NFS and can
    # leave both sides with corrupt WAL/state. Keep sandbox runtime DBs
    # as real files under sandbox-config instead of symlinks to ~/.codex.
    shopt -s nullglob
    for target in "$config_dir"/*.sqlite* "$config_dir"/.nfs* "$config_dir/.*"; do
        [[ -L "$target" ]] && rm -f "$target" 2>/dev/null || true
    done
    shopt -u nullglob

    # --- Merge AGENTS.md ---
    local sandbox_snippet="$(_agent_file codex agent.md)"
    local user_agents_md="$real_codex_dir/AGENTS.md"
    {
        if [[ -f "$user_agents_md" ]]; then
            cat "$user_agents_md"
        fi
        if [[ -f "$sandbox_snippet" ]]; then
            echo ""
            sed "s|__SANDBOX_DIR__|$SANDBOX_DIR|g" "$sandbox_snippet"
        fi
    } > "$config_dir/AGENTS.md.tmp.$$"
    chmod a-w "$config_dir/AGENTS.md.tmp.$$" 2>/dev/null || true
    if ! mv -f "$config_dir/AGENTS.md.tmp.$$" "$config_dir/AGENTS.md" 2>/dev/null; then
        rm -f "$config_dir/AGENTS.md.tmp.$$" 2>/dev/null || true
    fi

    # --- Rewrite config.toml for sandbox-local SQLite ---
    # The sqlite_home config option takes precedence over CODEX_SQLITE_HOME,
    # so a symlinked config.toml would still point sandboxed Codex at the
    # host ~/.codex DBs. Force top-level sqlite_home to this sandbox config
    # dir, but keep config.toml WRITABLE so Codex can persist its own runtime
    # state (project trust_level / approvals) — and preserve those writes
    # across sessions unless the host config.toml is newer (then host wins).
    local user_config="$real_codex_dir/config.toml"
    local dest_config="$config_dir/config.toml"
    local base_config=""
    if [[ ! -f "$dest_config" || "$user_config" -nt "$dest_config" ]]; then
        # First run, or the host config was edited → re-derive from host.
        [[ -f "$user_config" ]] && base_config="$user_config"
    else
        # Up to date vs host → preserve Codex's in-session writes (approvals,
        # project trust); just re-assert sqlite_home in place (idempotent).
        base_config="$dest_config"
    fi
    if [[ -n "$base_config" ]]; then
        awk -v sqlite_home="$config_dir" '
            BEGIN { done = 0 }
            !done && /^[[:space:]]*sqlite_home[[:space:]]*=/ {
                print "sqlite_home = \"" sqlite_home "\""
                done = 1
                next
            }
            !done && /^[[:space:]]*\[/ {
                print "sqlite_home = \"" sqlite_home "\""
                done = 1
            }
            { print }
            END {
                if (!done) {
                    print "sqlite_home = \"" sqlite_home "\""
                }
            }
        ' "$base_config" > "$config_dir/config.toml.tmp.$$"
        if mv -f "$config_dir/config.toml.tmp.$$" "$dest_config" 2>/dev/null; then
            chmod u+w "$dest_config" 2>/dev/null || true
        else
            rm -f "$config_dir/config.toml.tmp.$$" 2>/dev/null || true
        fi
    fi

    # --- Symlink everything else (preserve fresher sandbox copies) ---
    for item in "$real_codex_dir"/* "$real_codex_dir"/.*; do
        local name
        name="$(basename "$item")"
        [[ "$name" == "." || "$name" == ".." ]] && continue
        case "$name" in
            AGENTS.md|config.toml|sandbox-config) continue ;;
            tmp) continue ;;                   # redirected to tmpfs below (arg0 NFS fix)
            .sandbox-AGENTS.md) continue ;;   # stale merged file from old overlay
            .nfs*) continue ;;                 # NFS delete placeholders from old sessions
            ".*") continue ;;                  # unmatched dotglob literal
            *.sqlite*) continue ;;             # sandbox owns its runtime SQLite DBs
            db-backups) continue ;;            # backups are specific to the DB home
        esac
        local target="$config_dir/$name"
        if [[ -e "$target" && ! -L "$target" && "$target" -nt "$item" ]]; then
            continue
        fi
        if [[ -L "$target" && "$(readlink "$target")" == "$item" ]]; then
            continue
        fi
        ln -snf "$item" "$target" 2>/dev/null || true
    done

    # --- Redirect Codex's arg0 helper dir onto the sandbox tmpfs ---
    # Codex creates a per-run dir under $CODEX_HOME/tmp/arg0/ for its argv[0]
    # re-exec. On NFS, an arg0 file still held open by a (possibly concurrent)
    # Codex is silly-renamed to .nfsXXXX on delete, so rmdir fails ENOTEMPTY,
    # the cleanup bails, and empty dirs pile up. Point $CODEX_HOME/tmp at the
    # sandbox's private tmpfs /tmp so arg0 dirs never touch NFS and are cleared
    # automatically on sandbox exit. (Codex's default workspace-write policy
    # already treats /tmp as writable.)
    #
    # Target /tmp directly (not a subdir): the symlink is created on the host
    # during prepare, before the sandbox's private tmpfs /tmp exists, so a
    # subdir target would be a dangling link and `mkdir -p` would refuse to
    # traverse it. /tmp always exists in the sandbox, so arg0 dirs land at
    # /tmp/arg0/ on tmpfs.
    if [[ -e "$config_dir/tmp" && ! -L "$config_dir/tmp" ]]; then
        rm -rf "$config_dir/tmp" 2>/dev/null || true
    fi
    ln -snf /tmp "$config_dir/tmp" 2>/dev/null || true

    _AGENT_SANDBOX_CONFIG_DIRS+=("$config_dir")
    _AGENT_PROTECTED_FILES+=("$config_dir/AGENTS.md")
    # NOTE: config.toml is intentionally NOT protected/read-only — Codex must be
    # able to persist approvals / project trust into it (sqlite_home is
    # re-asserted on every start, so it can't be lost).

    # Export CODEX_HOME so Codex reads from merged config
    _AGENT_ENV_EXPORTS+=("CODEX_HOME=$config_dir")
    _AGENT_ENV_EXPORTS+=("CODEX_SQLITE_HOME=$config_dir")
}

agent_get_env_exports() {
    # CODEX_HOME is set by agent_prepare_config via _AGENT_ENV_EXPORTS
    :
}
