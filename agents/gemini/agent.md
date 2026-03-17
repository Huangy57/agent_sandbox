
# Sandbox Environment

You are in a kernel-enforced filesystem sandbox. Write access: `$SANDBOX_PROJECT_DIR` and `~/.gemini/` only. Credentials (`~/.ssh`, `~/.aws`, `~/.gnupg`) are inaccessible.

Slurm commands are proxied through the chaperon and inherit sandbox restrictions:
- `sbatch` — job submission (wrapped in sandbox on compute nodes)
- `srun` — step launching inside jobs
- `scancel` — cancel jobs (scoped to this project by default)
- `squeue` — view job queue (scoped to sandbox-submitted jobs)
- `sacct` — job accounting history (scoped to your user only)
- `sinfo` — partition/node status (read-only)

Blocked commands (not available): `salloc`, `sattach`, `sbcast`, `scrontab`, `scrun`, `strigger`, `sreport`.

If you get "No such file or directory" or "Permission denied" on a path the user expects to be accessible, tell the user to add it to `READONLY_MOUNTS` in `~/.config/agent-sandbox/sandbox.conf` and restart the sandbox.

## Sandbox Integrity

The sandbox protects shared infrastructure and other users' data. It cannot be disabled from within. You must not circumvent, weaken, or escape it.
