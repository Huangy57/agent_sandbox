# Admin Hardening Guide

The [bubblewrap sandbox](README.md) is fully user-space — no root or admin involvement needed. It provides kernel-enforced filesystem isolation for AI coding agents, with Slurm job wrapping as a default-on soft boundary.

This document is a menu of **independent improvements** an admin can adopt to close remaining gaps. Each section is self-contained: pick what fits your threat model and effort budget. They are ordered roughly from least to most effort.

---

## 1. System-Wide Bubblewrap Installation

**What it solves:** Each user currently installs bubblewrap via Homebrew, which is fragile and duplicated across accounts.

**Effort:** Low (one-time package install or module build).

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

## 2. Kernel-Enforced Slurm Sandboxing (job_submit Plugin)

**What it solves:** The current Slurm wrappers shadow `sbatch`/`srun` on PATH, but an agent could call `/usr/bin/sbatch` directly to bypass them. A `job_submit` plugin enforces sandboxing at the scheduler level — the controller rejects non-sandboxed jobs before they reach a compute node.

**Effort:** Medium (Lua plugin + Slurm config reload).

**How:**

Slurm's `job_submit/lua` plugin runs a Lua function on every job submission. You can inspect the job script or command and reject submissions that don't include the bwrap wrapper.

**Example `/etc/slurm/job_submit.lua`:**

```lua
function slurm_job_submit(job_desc, part_list, submit_uid)
    -- Only enforce for AI agent accounts/QOS
    local dominated_qos = {"agent", "ai_sandbox"}
    local dominated_accounts = {"dotto_ai", "labuser_ai"}

    local dominated = false
    for _, q in ipairs(dominated_qos) do
        if job_desc.qos == q then dominated = true end
    end
    for _, a in ipairs(dominated_accounts) do
        if job_desc.account == a then dominated = true end
    end

    if not dominated then
        return slurm.SUCCESS  -- normal users pass through
    end

    -- Check that the job command includes bwrap-sandbox.sh
    local script = job_desc.script or ""
    local wrap = job_desc.work_dir or ""

    if not string.find(script, "bwrap%-sandbox%.sh") and
       not string.find(job_desc.argv_str or "", "bwrap%-sandbox%.sh") then
        slurm.log_info("job_submit/lua: rejecting unsandboxed job from account %s",
                       job_desc.account or "unknown")
        return slurm.ERROR
    end

    return slurm.SUCCESS
end

function slurm_job_modify(job_desc, job_rec, part_list, modify_uid)
    return slurm.SUCCESS
end
```

**Enable in `slurm.conf`:**

```
JobSubmitPlugins=job_submit/lua
```

Then `scontrol reconfigure`.

**Complements:** Works independently of user-space wrappers. Even if an agent bypasses PATH shadowing, the scheduler itself refuses the job.

---

## 3. Slurm TaskProlog Alternative

**What it solves:** Same as the `job_submit` plugin — ensures compute-node jobs run inside bwrap — but implemented as a prolog script that wraps the job at execution time rather than rejecting it at submission.

**Effort:** Low-medium (simpler than the Lua plugin, but less clean since wrapping happens after scheduling).

**How:**

A `TaskProlog` script runs on the compute node before each job step. It can re-exec the job inside bwrap based on account, QOS, or an environment variable.

**Example `/etc/slurm/task_prolog.sh`:**

```bash
#!/bin/bash
# Only wrap jobs from AI agent accounts
case "$SLURM_JOB_ACCOUNT" in
    *_ai)
        # Already inside bwrap? Skip.
        if [[ "${SANDBOX_ACTIVE:-}" == "1" ]]; then
            exit 0
        fi

        SANDBOX_DIR="/fh/fast/${SLURM_JOB_ACCOUNT%_ai}/.claude/sandbox"
        if [[ -x "$SANDBOX_DIR/bwrap-sandbox.sh" ]]; then
            export SLURM_TASK_PROLOG_SANDBOX=1
            exec "$SANDBOX_DIR/bwrap-sandbox.sh" \
                --project-dir "${SLURM_SUBMIT_DIR:-$PWD}" \
                -- "$@"
        fi
        ;;
esac
exit 0
```

**Enable in `slurm.conf`:**

```
TaskProlog=/etc/slurm/task_prolog.sh
```

**Tradeoff vs. job_submit plugin:**
- **TaskProlog**: Easier to deploy, no Lua, works with any Slurm version that supports TaskProlog. But the job is already scheduled when wrapping happens.
- **job_submit**: Rejects bad jobs before scheduling, cleaner separation. Requires Lua plugin support.

Both approaches key off the Slurm account name, so they pair naturally with dedicated `${USER}_ai` accounts (Section 4).

---

## 4. Dedicated `${USER}_ai` Accounts

**What it solves:** True user separation. No amount of bubblewrap can prevent a process from accessing files owned by the same UID. A dedicated OS account (`dotto_ai`) runs the agent under a different UID, so filesystem permissions enforce isolation without any sandbox at all.

**Effort:** High (new accounts, group structure, Slurm associations, ACLs).

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

## 5. Network Isolation

**What it solves:** The current sandbox shares the host network stack (required for munge authentication and Slurm communication). This means an agent could use `curl` or `wget` to exfiltrate data.

**Effort:** Medium-high (requires root, iptables/nftables or network namespace configuration).

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

## 6. Kernel Upgrade and Landlock

**What it solves:** The current kernel (4.15) doesn't support [Landlock](https://docs.kernel.org/userspace-api/landlock.html), a Linux Security Module available since kernel 5.13. Landlock provides per-process filesystem access rules without requiring mount namespaces.

**Effort:** High (kernel upgrade across the cluster).

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

## 7. Audit Logging

**What it solves:** Visibility into what the agent did — which files it accessed, which jobs it submitted, and what commands it ran. Useful for compliance, forensics, and debugging.

**Effort:** Low-medium (auditd rules + Slurm accounting config).

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

With dedicated Slurm accounts (Section 4), all agent jobs are automatically tracked:

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

| # | Improvement | Effort | What It Closes |
|---|---|---|---|
| 1 | System-wide bwrap install | Low | Fragile per-user Homebrew installs |
| 2 | Slurm job_submit plugin | Medium | Agent bypassing Slurm wrappers via absolute path |
| 3 | Slurm TaskProlog | Low-medium | Same as #2 (alternative approach) |
| 4 | Dedicated `${USER}_ai` accounts | High | Same-UID credential access; OS-level separation |
| 5 | Network isolation | Medium-high | Data exfiltration via network |
| 6 | Kernel upgrade + Landlock | High | Simpler/stronger filesystem restrictions |
| 7 | Audit logging | Low-medium | Visibility, compliance, forensics |

Choose #2 **or** #3 (not both). All other sections are independent and complementary.
