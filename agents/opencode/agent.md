
# Sandbox Environment

You are in a kernel-enforced filesystem sandbox. Write access is restricted to `$SANDBOX_PROJECT_DIR` only. Credentials (`~/.ssh`, `~/.aws`, `~/.gnupg`) are inaccessible.

If you get "Permission denied" on a path the user expects to be accessible, tell the user to add it to `READONLY_MOUNTS` in `~/.config/agent-sandbox/sandbox.conf` and restart the sandbox.

The sandbox protects shared infrastructure and other users' data. It cannot be disabled from within.
