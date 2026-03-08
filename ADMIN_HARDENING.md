# Admin Hardening Guide

The [bubblewrap sandbox](README.md) is fully user-space — no root or admin involvement needed. It provides kernel-enforced filesystem isolation for AI coding agents, with Slurm job wrapping as a default-on soft boundary.

This document is a menu of **independent improvements** an admin can adopt to close remaining gaps. Each section is self-contained: pick what fits your threat model and effort budget. They are ordered roughly from least to most effort.

### Self-serve vs. admin-enforced

Each improvement falls into one of two categories:

- **Self-serve** — makes it easier for users to sandbox their agents correctly. Works when users follow the setup. Does not prevent a user (or their agent) from bypassing the protection if they try.
- **Admin-enforced** — the admin controls the enforcement mechanism. Users and agents cannot bypass it, even deliberately.

The current user-space sandbox is entirely self-serve: it protects against accidental exposure and autonomous agent misbehavior, but a user who instructs their agent to bypass it can do so. The improvements below range from making the self-serve path smoother to adding hard admin-enforced boundaries.

---

## 1. System-Wide Bubblewrap Installation

**What it solves:** Each user currently installs bubblewrap via Homebrew, which is fragile and duplicated across accounts.

**Effort:** Low (one-time package install or module build). **Category:** Self-serve.

**How:**

Install bwrap system-wide so every user gets it without Homebrew:

```bash
# Option A: Package manager (if distro supports it)
apt install bubblewrap        # Debian/Ubuntu
dnf install bubblewrap        # RHEL/Fedora

# Option B: Install to /app (site convention)
# Build from source, install to /app/bubblewrap/<version>/bin/bwrap

# Option C: Lmod module
# Create a modulefile that prepends /app/bubblewrap/<version>/bin to PATH
```

The sandbox scripts find bwrap via `PATH`, so no script changes are needed — just ensure `bwrap` is available on login and compute nodes.

**Complements:** Everything below. This is the simplest starting point.

---

## 2. Admin-Managed Slurm Wrappers

**What it solves:** The user-space sandbox intercepts `sbatch`/`srun` via PATH shadowing, but an agent calling `/usr/bin/sbatch` by absolute path bypasses the wrappers. Admin-managed wrappers make it so the real Slurm binaries **won't work** inside the sandbox, even if called directly.

**Effort:** Medium. **Category:** Admin-enforced.

### Concept

The admin makes two changes:

1. **Gate the real Slurm submission binaries behind a credential** that the sandbox blocks — a token file, env var, or socket that's hidden inside bwrap.
2. **Provide enforcing wrappers** that submit jobs via an alternative path that doesn't require the blocked credential.

Inside the bwrap sandbox:
- The agent calls `sbatch` → hits the enforcing wrapper (via PATH or bind-mount overlay) → job is wrapped in bwrap → submitted successfully via the alternative path
- The agent calls `/usr/bin/sbatch` directly (bypass attempt) → the real binary runs but **fails authentication** because the required credential is missing inside the sandbox

Outside the sandbox, the credential exists — normal user workflow is completely unaffected.

### Example: token-file gate

**Step 1 — Gate the real binaries.** Replace `/usr/bin/sbatch` with a gateway that checks for a token before calling the real binary:

```bash
#!/bin/bash
# /usr/bin/sbatch — gateway wrapper (admin-installed)
SUBMIT_TOKEN="/etc/slurm/.submit-token"
if [[ ! -r "$SUBMIT_TOKEN" ]]; then
    echo "sbatch: direct submission not available in this environment." >&2
    echo "Hint: use the sandboxed sbatch on your PATH." >&2
    exit 1
fi
exec /usr/libexec/slurm/sbatch-real "$@"
```

```bash
# One-time admin setup
mkdir -p /usr/libexec/slurm
mv /usr/bin/sbatch /usr/libexec/slurm/sbatch-real
mv /usr/bin/srun   /usr/libexec/slurm/srun-real
install -m 0755 gateway-sbatch /usr/bin/sbatch
install -m 0755 gateway-srun   /usr/bin/srun
echo "submit-allowed" > /etc/slurm/.submit-token
chmod 0644 /etc/slurm/.submit-token
```

**Step 2 — Hide the token inside bwrap.** Add to the sandbox bwrap arguments:

```bash
--ro-bind /dev/null /etc/slurm/.submit-token    # token appears empty
```

Now any direct call to `/usr/bin/sbatch` inside the sandbox fails — the gateway can't read the token.

**Step 3 — Enforcing wrappers submit via slurmrestd.** The sandboxed wrappers don't call the real sbatch at all. They submit jobs through the [Slurm REST API](https://slurm.schedmd.com/rest_api.html) (slurmrestd), which authenticates via a different mechanism (e.g., JWT service token passed by the wrapper, or Unix socket auth):

```bash
#!/bin/bash
# Enforcing sbatch wrapper (simplified)
# Wraps the job command in bwrap, submits via REST API
BWRAP_SANDBOX="$HOME/.claude/sandbox/bwrap-sandbox.sh"
PROJECT_DIR="${SANDBOX_PROJECT_DIR:-$(pwd)}"

# ... parse sbatch flags, build wrapped job script ...

# Submit via slurmrestd instead of calling the real sbatch binary
curl -s -X POST "http://localhost:6820/slurm/v0.0.40/job/submit" \
    -H "Content-Type: application/json" \
    -d @wrapped_job.json
```

### Alternative credentials to gate on

The token file is the simplest example, but admins can gate on whatever is convenient:

| Credential | How to block in bwrap | Notes |
|---|---|---|
| Token file (`/etc/slurm/.submit-token`) | `--ro-bind /dev/null /etc/slurm/.submit-token` | Simplest; easy to audit |
| Munge socket (`/run/munge/munge.socket.2`) | Don't mount `/run/munge/` | Blocks all munge auth; enforcing wrappers must use JWT or slurmrestd |
| Environment variable (`SLURM_SUBMIT_KEY`) | Add to `BLOCKED_ENV_VARS` in `sandbox.conf` | Easy but env vars are more discoverable |

### Why this doesn't require `${USER}_ai` accounts

The enforcement is structural: the sandbox mount configuration determines what credentials are available, not the UID. Any session running inside bwrap loses the submission credential, regardless of which user started it.

---

## 3. Dedicated `${USER}_ai` Accounts

**What it solves:** True user separation. No amount of bubblewrap can prevent a process from accessing files owned by the same UID. A dedicated OS account (`dotto_ai`) runs the agent under a different UID, so filesystem permissions enforce isolation without any sandbox at all.

**Effort:** High (new accounts, group structure, Slurm associations, ACLs). **Category:** Admin-enforced.

### Account and Group Structure

```
User account:   dotto        (UID 1001, primary group: dotto)
Agent account:  dotto_ai     (UID 2001, primary group: dotto_ai)
Lab AI group:   setty_m_ai   (GID 3001)
```

**Group memberships:**

| Account | Groups | Purpose |
|---|---|---|
| `dotto` | `dotto`, `dotto_ai`, `setty_m` | Human can read agent output (via `dotto_ai` group) |
| `dotto_ai` | `dotto_ai`, `setty_m_ai` | Agent creates files owned by `dotto_ai`; lab-wide agent collaboration via `setty_m_ai` |

This means:
- Files the agent creates are owned by `dotto_ai:dotto_ai`
- The human (`dotto`) is in the `dotto_ai` group, so they can read/manage agent output
- Multiple agents in the lab share `setty_m_ai` for cross-user collaboration
- The agent **cannot** read `dotto`'s private files (SSH keys, credentials) because it's a different UID

### Slurm Association

Create a separate Slurm account and QOS with resource limits:

```bash
sacctmgr add account ai_agents Description="AI agent jobs"
sacctmgr add user dotto_ai Account=ai_agents

# Optional: limit resources via QOS
sacctmgr add qos agent_qos \
    MaxTRESPerUser=cpu=64,gres/gpu=2 \
    MaxJobsPerUser=10 \
    MaxSubmitJobsPerUser=20 \
    Priority=10
sacctmgr modify user dotto_ai set DefaultQOS=agent_qos
```

### File Permissions

Use POSIX ACLs on shared data directories so agents can read lab data but not private dirs:

```bash
# Lab shared data: agents can read
setfacl -R -m g:setty_m_ai:rX /fh/fast/setty_m/shared_data

# User private dirs: no agent access (default — different UID, no group overlap)
# dotto_ai cannot read /home/dotto/.ssh — OS enforces this

# Agent workspace: both human and agent can read/write
mkdir -p /fh/fast/setty_m/user/dotto/agent_workspace
chown dotto_ai:dotto_ai /fh/fast/setty_m/user/dotto/agent_workspace
chmod 2775 /fh/fast/setty_m/user/dotto/agent_workspace
```

### Role of bwrap with Dedicated Accounts

OS user separation handles credential isolation — the agent physically cannot read `dotto`'s SSH keys or AWS credentials because they're owned by a different UID. However, bwrap remains useful for **fine-grained write restriction within allowed paths**: the agent account may have write access to multiple project directories, but bwrap can restrict a given session to only one.

---

## 4. Network Isolation

**What it solves:** The current sandbox shares the host network stack (required for munge authentication and Slurm communication). This means an agent could use `curl` or `wget` to exfiltrate data.

**Effort:** Medium-high (requires root, iptables/nftables or network namespace configuration). **Category:** Admin-enforced.

### Option A: Per-UID iptables Rules

Block outbound network for agent UIDs, allowing only what's needed:

```bash
# Allow loopback and established connections
iptables -A OUTPUT -m owner --uid-owner dotto_ai -o lo -j ACCEPT
iptables -A OUTPUT -m owner --uid-owner dotto_ai -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow munge (unix socket — no iptables rule needed, it's local)
# Allow Slurm controller communication
iptables -A OUTPUT -m owner --uid-owner dotto_ai -d <slurmctld_ip> -p tcp --dport 6817 -j ACCEPT

# Allow DNS
iptables -A OUTPUT -m owner --uid-owner dotto_ai -p udp --dport 53 -j ACCEPT

# Block everything else
iptables -A OUTPUT -m owner --uid-owner dotto_ai -j DROP
```

### Option B: Network Namespace with Socket Forwarding

Run the agent in a network namespace with only the munge socket forwarded:

```bash
# Create namespace
ip netns add agent_ns

# Forward munge socket using socat
socat UNIX-LISTEN:/run/netns/agent_ns/munge.sock,fork \
      UNIX-CONNECT:/run/munge/munge.socket.2 &

# Run agent in namespace
ip netns exec agent_ns su - dotto_ai -c "claude"
```

This is more complex but provides stronger isolation — the agent has no network interfaces at all, just the munge socket.

**Complements:** Pairs naturally with dedicated `${USER}_ai` accounts (the iptables rules key off UID).

---

## 5. Kernel Upgrade and Landlock

**What it solves:** The current kernel (4.15) doesn't support [Landlock](https://docs.kernel.org/userspace-api/landlock.html), a Linux Security Module available since kernel 5.13. Landlock provides per-process filesystem access rules without requiring mount namespaces.

**Effort:** High (kernel upgrade across the cluster). **Category:** Self-serve (process restricts itself) or admin-enforced (if configured via system policy).

### What Landlock Provides

Landlock lets an unprivileged process restrict its own filesystem access using a ruleset:

```c
// Pseudocode — Landlock access rule model
struct landlock_ruleset_attr ruleset_attr = {
    .handled_access_fs = LANDLOCK_ACCESS_FS_READ_FILE |
                         LANDLOCK_ACCESS_FS_WRITE_FILE |
                         LANDLOCK_ACCESS_FS_EXECUTE
};

int ruleset_fd = landlock_create_ruleset(&ruleset_attr, ...);

// Allow read access to /fh/fast/setty_m
landlock_add_rule(ruleset_fd, LANDLOCK_RULE_PATH_BENEATH, &(struct landlock_path_beneath_attr){
    .allowed_access = LANDLOCK_ACCESS_FS_READ_FILE,
    .parent_fd = open("/fh/fast/setty_m", O_PATH)
});

// Allow write access to project dir only
landlock_add_rule(ruleset_fd, LANDLOCK_RULE_PATH_BENEATH, &(struct landlock_path_beneath_attr){
    .allowed_access = LANDLOCK_ACCESS_FS_READ_FILE | LANDLOCK_ACCESS_FS_WRITE_FILE,
    .parent_fd = open("/fh/fast/setty_m/user/dotto/project", O_PATH)
});

// Enforce — cannot be undone by the process
landlock_restrict_self(ruleset_fd, 0);
```

Once enforced, the process (and all its children) cannot access anything outside the ruleset. Unlike bwrap, Landlock doesn't use mount namespaces — it works with the real filesystem, just restricts what the process can see.

### How It Complements bwrap

- **bwrap** provides mount-namespace isolation: the agent sees a curated filesystem. Good for hiding paths entirely (e.g., `~/.ssh` doesn't exist).
- **Landlock** provides access-control isolation: the agent sees the real filesystem but can't access restricted paths. Good for fine-grained rules without mount overhead.

On kernel >= 5.13, you could use Landlock instead of bwrap for simpler setups, or layer it on top of bwrap for defense in depth.

### Kernel Version Check

```bash
uname -r
# 4.15.0-213-generic  ← too old for Landlock

# Landlock requires:
# - Kernel >= 5.13
# - CONFIG_SECURITY_LANDLOCK=y
# - LSM boot parameter includes "landlock"
```

---

## 6. Audit Logging

**What it solves:** Visibility into what the agent did — which files it accessed, which jobs it submitted, and what commands it ran. Useful for compliance, forensics, and debugging.

**Effort:** Low-medium (auditd rules + Slurm accounting config). **Category:** Admin-enforced.

### File Access Auditing with auditd

Log all file access by agent accounts:

```bash
# /etc/audit/rules.d/agent-audit.rules

# Log file opens by dotto_ai
-a always,exit -F arch=b64 -S open,openat -F uid=2001 -k agent_file_access

# Log process execution by dotto_ai
-a always,exit -F arch=b64 -S execve -F uid=2001 -k agent_exec

# Log network connections by dotto_ai
-a always,exit -F arch=b64 -S connect -F uid=2001 -k agent_network
```

Reload rules:

```bash
augenrules --load
```

Query logs:

```bash
# What files did the agent open?
ausearch -k agent_file_access --uid 2001 -ts today

# What commands did it run?
ausearch -k agent_exec --uid 2001 -ts today
```

### Slurm Job Accounting

With dedicated Slurm accounts (Section 3), all agent jobs are automatically tracked:

```bash
# All jobs submitted by agent accounts
sacct -a --accounts=ai_agents --starttime=2024-01-01 \
    --format=JobID,User,Account,JobName,State,ExitCode,Start,End,Elapsed,MaxRSS

# Resource usage summary
sreport cluster AccountUtilizationByUser Accounts=ai_agents Start=2024-01-01
```

The separate account/QOS makes it trivial to query, report on, and set limits for agent workloads without any custom tooling.

**Complements:** Pairs with dedicated `${USER}_ai` accounts for UID-based audit rules and with Slurm account/QOS for job-level tracking.

---

## Summary

| # | Improvement | Effort | Category | What It Closes |
|---|---|---|---|---|
| 1 | System-wide bwrap install | Low | Self-serve | Fragile per-user Homebrew installs |
| 2 | Admin-managed Slurm wrappers | Medium | Admin-enforced | Agent bypassing Slurm wrappers by absolute path |
| 3 | Dedicated `${USER}_ai` accounts | High | Admin-enforced | Same-UID credential access; OS-level separation |
| 4 | Network isolation | Medium-high | Admin-enforced | Data exfiltration via network |
| 5 | Kernel upgrade + Landlock | High | Self-serve | Simpler/stronger filesystem restrictions |
| 6 | Audit logging | Low-medium | Admin-enforced | Visibility, compliance, forensics |

All sections are independent and complementary.
