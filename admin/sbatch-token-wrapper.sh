#!/usr/bin/env bash
# sbatch-token-wrapper.sh — System-wide sbatch wrapper for sandbox-by-default
#
# Deploy as /usr/local/bin/sbatch (before /usr/bin in PATH) so that all
# users transparently get the bypass token injected. Non-sandboxed
# processes can read the token file (eBPF allows it), so their jobs pass
# through the job submit plugin unsandboxed — no workflow change needed.
# Sandboxed processes cannot read the token (eBPF denies it via
# no_new_privs check), so their jobs lack the token and get sandboxed
# by the plugin.
#
# The token is injected as an environment variable (not a CLI argument)
# so it never appears in /proc/*/cmdline. Any _SANDBOX_BYPASS passed
# via --export= is stripped to prevent manual token injection.
#
# Requires:
#   - job_submit.lua plugin loaded in slurmctld
#   - eBPF LSM token protection active
#   - Token file at TOKEN_FILE (below)

TOKEN_FILE="/etc/slurm/.sandbox-bypass-token"
REAL_SBATCH="/usr/bin/sbatch"

# Strip any _SANDBOX_BYPASS from --export= flags (prevent manual injection
# via command line, which would be visible in the process table).
ARGS=()
for arg in "$@"; do
    case "$arg" in
        --export=*)
            # Remove _SANDBOX_BYPASS from comma-separated export list
            cleaned=$(echo "${arg#--export=}" | sed 's/,\?_SANDBOX_BYPASS=[^,]*//' | sed 's/^,//')
            if [[ -n "$cleaned" ]]; then
                ARGS+=("--export=$cleaned")
            fi
            ;;
        *)
            ARGS+=("$arg")
            ;;
    esac
done

# Also clear any _SANDBOX_BYPASS from the inherited environment
unset _SANDBOX_BYPASS

# Try to read the token. This succeeds for normal users and fails for
# sandboxed processes (eBPF returns EACCES when no_new_privs is set).
TOKEN=$(cat "$TOKEN_FILE" 2>/dev/null) || true

if [[ -n "$TOKEN" ]]; then
    # Token readable — inject via environment variable only.
    export _SANDBOX_BYPASS="$TOKEN"
fi

exec "$REAL_SBATCH" "${ARGS[@]}"
