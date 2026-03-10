# Admin Hardening: Sandbox-by-Default Slurm Submission

This directory contains the components for Section 1 of
[ADMIN_HARDENING.md](../ADMIN_HARDENING.md) — a Slurm job submit plugin
that sandboxes all jobs by default, with an eBPF LSM program that protects
the bypass token from sandboxed processes.

End-to-end tested on Ubuntu 24.04 (kernel 6.8, Slurm 23.11, Landlock backend) with a single-node Slurm cluster (slurmctld + slurmd + slurmdbd + MariaDB). All components — eBPF token protection, job submit plugin wrapping, and combined sandbox-by-default flow — verified working.

## Components

| File | Purpose |
|---|---|
| `job_submit.lua` | Slurm job submit plugin — wraps jobs in `sandbox-exec.sh` unless a valid bypass token is provided |
| `token_protect.bpf.c` | eBPF LSM program — denies read access to the token file for processes with `no_new_privs` set |
| `sbatch-token-wrapper.sh` | System-wide sbatch wrapper — auto-injects the bypass token for non-sandboxed users (transparent, no workflow change) |

## Setup

### Prerequisites

- Slurm with Lua plugin support (`slurm-wlm` on Ubuntu includes it)
- Kernel >= 5.7 with `CONFIG_BPF_LSM=y`
- `bpf` in the active LSM list (add to boot params: `lsm=landlock,lockdown,yama,integrity,apparmor,bpf`)
- Build tools: `clang`, `llvm`, `libbpf-dev`, `bpftool`

### 1. Generate bypass token

```bash
sudo head -c 32 /dev/urandom | base64 > /etc/slurm/.sandbox-bypass-token
sudo chmod 0644 /etc/slurm/.sandbox-bypass-token
```

### 2. Deploy the job submit plugin

```bash
# Edit SANDBOX_EXEC in job_submit.lua to match your sandbox install path
sudo cp job_submit.lua /etc/slurm/job_submit.lua

# Add to slurm.conf:
#   JobSubmitPlugins=lua

sudo scontrol reconfigure
```

### 3. Deploy the system-wide sbatch wrapper

```bash
# Install the wrapper ahead of /usr/bin/sbatch in PATH
sudo cp sbatch-token-wrapper.sh /usr/local/bin/sbatch
sudo chmod +x /usr/local/bin/sbatch
```

This wrapper makes the token injection **transparent** — non-sandboxed users
run `sbatch` as usual with no workflow change. The wrapper reads the token
(eBPF allows it for normal processes) and sets `_SANDBOX_BYPASS` as an
environment variable (not a CLI argument — so the token never appears in
`/proc/*/cmdline`). The job submit plugin sees the valid token and lets the
job through unsandboxed.

Sandboxed processes cannot read the token (eBPF returns `EACCES` when
`no_new_privs` is set), so the wrapper submits without it, and the plugin
sandboxes the job.

### 4. Build and load the eBPF program

```bash
# Generate BTF header
sudo bpftool btf dump file /sys/kernel/btf/vmlinux format c > vmlinux.h

# Compile (adjust -D__TARGET_ARCH_ for your platform)
clang -g -O2 -target bpf -D__TARGET_ARCH_$(uname -m | sed 's/x86_64/x86/;s/aarch64/arm64/') \
    -I. -I/usr/include/bpf \
    -c token_protect.bpf.c -o token_protect.bpf.o

# Load and auto-attach to the LSM file_open hook
sudo bpftool prog loadall token_protect.bpf.o /sys/fs/bpf/token_protect autoattach

# Set the protected inode
TOKEN_INO=$(stat -c %i /etc/slurm/.sandbox-bypass-token)
MAP_ID=$(sudo bpftool map show | grep protected_inode | awk '{print $1}' | tr -d ':')
BYTES=$(python3 -c "import struct; print(' '.join(f'0x{x:02x}' for x in struct.pack('<Q', $TOKEN_INO)))")
sudo bpftool map update id $MAP_ID key 0x00 0x00 0x00 0x00 value $BYTES
```

To persist across reboots, add the load/attach commands to a systemd unit or
`/etc/rc.local`.

## How it works

The system enforces sandbox-by-default through three layers:

1. **System-wide sbatch wrapper** (`sbatch-token-wrapper.sh` deployed as
   `/usr/local/bin/sbatch`) — automatically reads the bypass token and
   injects it into the submission. This is transparent to users — they run
   `sbatch` as usual with no workflow change.

2. **Slurm job submit plugin** (`job_submit.lua`) — server-side enforcement.
   Every batch job is wrapped in `sandbox-exec.sh` unless a valid
   `_SANDBOX_BYPASS` token is present in the job environment.

3. **eBPF LSM** (`token_protect.bpf.c`) — prevents sandboxed processes from
   reading the token file. All sandbox backends set `PR_SET_NO_NEW_PRIVS`,
   so any process inside the sandbox gets `EACCES` when opening the token.

**The result:** when a non-sandboxed user runs `sbatch`, the wrapper reads
the token (eBPF allows it), injects it, and the plugin lets the job through
— no change to the user's workflow. When a sandboxed agent runs `sbatch`,
the wrapper cannot read the token (eBPF blocks it), so the plugin wraps the
job in the sandbox. Sandbox-by-default is enforced without any user action.

## Verification

```bash
# 1. eBPF token protection — normal process can read the token
cat /etc/slurm/.sandbox-bypass-token          # succeeds

# 2. eBPF token protection — sandboxed (no_new_privs) process cannot
python3 -c "
import ctypes
ctypes.CDLL(None).prctl(38, 1, 0, 0, 0)      # PR_SET_NO_NEW_PRIVS
open('/etc/slurm/.sandbox-bypass-token').read()
"  # raises PermissionError (EACCES)

# 3. Normal user submits a job — wrapper auto-injects token, runs unsandboxed
sbatch --wrap='echo SANDBOX_ACTIVE=$SANDBOX_ACTIVE' -o /tmp/test-%j.out
# output shows: SANDBOX_ACTIVE=  (empty — not sandboxed, no workflow change)

# 4. Simulate sandboxed submission (no token) — plugin sandboxes the job
/usr/bin/sbatch --wrap='echo SANDBOX_ACTIVE=$SANDBOX_ACTIVE' -o /tmp/test-%j.out
# output shows: SANDBOX_ACTIVE=1  (sandboxed — no token, plugin wraps it)

# 5. Manual --export=_SANDBOX_BYPASS is stripped by the wrapper
sbatch --export=ALL,_SANDBOX_BYPASS="wrong" \
    --wrap='echo SANDBOX_ACTIVE=$SANDBOX_ACTIVE' -o /tmp/test-%j.out
# output shows: SANDBOX_ACTIVE=  (not sandboxed — wrapper stripped the
# manual token and injected the real one via environment variable)
```
