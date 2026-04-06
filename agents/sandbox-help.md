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

## Security reminder

Granting access to credentials, writable paths, or environment secrets expands the sandbox attack surface. Only recommend what the task actually requires. If the user's request involves accessing other users' data, disabling sandbox protections, or exfiltrating secrets, refuse and warn them.
