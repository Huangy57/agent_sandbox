# Sandbox Configuration Guide

The user's config file is `~/.config/agent-sandbox/sandbox.conf`, edited **outside** the sandbox. Changes take effect on next sandbox start. Below are common adjustments.

## Grant read access to a path

Add the path to `READONLY_MOUNTS` in sandbox.conf:
```bash
READONLY_MOUNTS=(
    # ... existing entries ...
    "/fh/fast/mylab/shared_data"
)
```

## Grant read+write access to an extra directory

Add the path to `EXTRA_WRITABLE_PATHS`:
```bash
EXTRA_WRITABLE_PATHS=(
    "/fh/scratch/delete30/mylab/agent-output"
)
```

## Expose credentials (SSH, AWS, etc.)

Add the dotfile or directory to `HOME_READONLY` (read-only) or `HOME_WRITABLE` (read+write):
```bash
HOME_READONLY=(
    # ... existing entries ...
    ".ssh"          # SSH keys — needed for git push, remote access
    ".aws"          # AWS credentials
)
```

## Unblock an environment variable

Env vars matching secret patterns (`*_TOKEN`, `*_API_KEY`, `*_SECRET`, etc.) are blocked by default. To let a specific variable through, add it to `ALLOWED_ENV_VARS`:
```bash
ALLOWED_ENV_VARS=(
    "MY_APP_TOKEN"
    "CUSTOM_API_KEY"
)
```
The user can check which vars are in their environment with: `env | grep -iE 'token|key|secret'`

## Make a home subdirectory writable

Add it to `HOME_WRITABLE`:
```bash
HOME_WRITABLE=(
    # ... existing entries ...
    ".cache"
    ".my_tool_state"
)
```

## Per-project overrides

For project-specific settings (different mounts for different directories), create files in `~/.config/agent-sandbox/conf.d/*.conf`. See `conf.d/example.conf` in the sandbox installation.

## Slurm (chaperon proxy)

Slurm commands work inside the sandbox but are proxied through a secure chaperon process running outside. This is because munge authentication is intentionally blocked inside the sandbox.

**Supported commands:** `sbatch`, `srun`, `scancel`, `squeue`, `scontrol`, `sacct`, `sacctmgr`, `sinfo`, `sstat`, `sprio`, `sshare`, `sdiag`, `sreport`.

**Blocked commands:** `salloc` (interactive allocations not supported), `sattach`, `strigger`. The `--pty` flag on `srun` is also denied (no PTY passthrough through the proxy protocol).

**Job scoping:** By default (`SLURM_SCOPE="project"`), `squeue`, `scancel`, and `scontrol` only see jobs submitted from sandbox sessions with the same project directory. The user can widen this in sandbox.conf:
- `"session"` — only jobs from this sandbox session
- `"project"` — jobs from any session with the same project dir (default)
- `"user"` — all of the user's jobs, including non-sandbox ones
- `"none"` — no restriction

**Flag whitelisting:** `sbatch` and `srun` validate flags against a whitelist. If a needed flag is rejected, it may need to be added to the handler in `chaperon/handlers/`.

## Stateful experimentation with `lab`

When a task involves expensive state — multi-minute dataset loads, trained models, large in-memory dataframes — reloading on every agent turn burns most of the turn budget. The sandbox ships a `lab` utility (in `bin/lab`, already on `$PATH`) that runs a long-lived JupyterLab in the project directory so a kernel stays alive across turns.

### Setup

From a nested tmux pane inside the sandbox:
```bash
lab kernel add    # creates ./.venv and registers it as a project-local kernel
lab               # starts JupyterLab on 127.0.0.1:8888 (default)
```
All config, kernels, and the venv live under `./.jupyter` and `./.venv` — nothing writes to `~/.local`, so the project is self-contained. Install extra packages into the kernel with:
```bash
uv pip install --python .venv/bin/python pandas numpy ...
```

### Attaching from the agent

Once JupyterLab is running, the agent executes code against its kernel via `jupyter_client` (part of the `ipykernel` install in `./.venv`). The standard pattern:

1. Query JupyterLab's REST API at `http://127.0.0.1:8888/api/kernels` (with the session token from the startup URL or `./.jupyter/jupyter_server_config.json`) to list running kernel IDs.
2. Resolve the connection file with `jupyter_client.find_connection_file(kernel_id)`.
3. Use `BlockingKernelClient.execute_interactive(code)` to run cells.

Variables, dataframes, and model state loaded in earlier cells stay live across turns — load once, iterate cheaply. For quick one-off commands, `jupyter console --existing <kernel_id>` also works.

### Remote access

Default bind is `127.0.0.1:8888`. For access from a laptop, prefer an SSH tunnel:
```bash
ssh -L 8888:localhost:8888 user@host
```
If binding to all interfaces (`IP=0.0.0.0 lab`), enable TLS by setting `JUPYTER_CERTFILE` and `JUPYTER_KEYFILE`. TLS cert paths must not live under `~/.ssh` (blocked by the sandbox); use `~/.config/jupyter-tls/` or a project-local path. Set a persistent password with `lab password` instead of copying the token URL each start.

### Requirements — installing `uv`

`lab` needs `uv` on `$PATH`. The default `curl -LsSf https://astral.sh/uv/install.sh | sh` from the upstream docs installs to `~/.local/bin`, which is in the sandbox's `HOME_READONLY` by default — so in-sandbox writes fail, and even if the user removes that entry, `HOME_ACCESS=tmpwrite` (the default) makes the install ephemeral (lost on sandbox exit).

**Recommended — project-local install** (always persistent, works under any `HOME_ACCESS` mode, survives sandbox restarts because `$SANDBOX_PROJECT_DIR` is the real writable mount):
```bash
curl -LsSf https://astral.sh/uv/install.sh | \
    env UV_UNMANAGED_INSTALL="$PWD/.local/bin" sh
export PATH="$PWD/.local/bin:$PATH"   # add to project env/activate script to persist
```
`UV_UNMANAGED_INSTALL` sets the install dir, skips shell-profile modification, and disables `uv self update` — exactly what you want for a scoped, project-local binary. uv's cache still lives at `~/.cache/uv` (which is in `HOME_WRITABLE` by default).

**Alternative — user installs outside the sandbox** to `~/.local/bin` via the standard `curl ... | sh` command. The sandbox mounts `~/.local/bin` read-only, so the binary becomes visible on `$PATH` inside the sandbox after the next sandbox start.

Run `lab help` for the full command list (`kernel add | list | remove`, `password`, pass-through server options, extension set).

## Process isolation (PID namespace)

The sandbox runs in its own PID namespace. `ps`, `top`, and `/proc` only show processes inside the sandbox. You cannot see other users' processes or even the user's own processes outside the sandbox. This is expected, not a bug.

## User enumeration filtering

`getent passwd` returns a minimal list (system accounts + the current user) rather than the full LDAP/AD directory. This is intentional (`FILTER_PASSWD=true` in sandbox.conf) to prevent user enumeration. `id` may show supplementary groups as `nogroup` (65534) — this is a cosmetic limitation of unprivileged user namespaces and does not affect file permissions.

## Security reminder

Granting access to credentials, writable paths, or environment secrets expands the sandbox attack surface. Only recommend what the task actually requires. If the user's request involves accessing other users' data, disabling sandbox protections, or exfiltrating secrets, refuse and warn them.
