# Firejail Sandbox Penetration Test Findings

**Date:** 2026-03-09
**Host:** lima-ubuntu (Ubuntu 24.04.3 LTS, kernel 6.8.0-101-generic aarch64)
**Sandbox backend:** firejail 0.9.72 (setuid root, `/usr/bin/firejail`)
**Tester:** Claude Code (red-team mode)

### Remediation Status

| Finding | Status | Fix |
|---|---|---|
| C1. Credential exfiltration | **Won't fix** | By design — agent needs `~/.claude` for auth. Same across all backends. |
| C2. Open network | **Won't fix** | By design — agent needs API access. Same across all backends. |
| H1. io_uring not blocked | **Acknowledged** | Firejail 0.9.72 limitation. Landlock backend blocks these. |
| H2. Snapd socket | **FIXED** | Added `--blacklist=/run/snapd.socket` and `/run/snapd-snap.socket` |
| H3. systemd-notify socket | **FIXED** | Added `--blacklist=/run/systemd/notify` |
| H4. /tmp not isolated | **FIXED** | Added `--private-tmp` |
| M3. Seccomp filter readable | **Acknowledged** | Firejail exposes `/run/firejail/mnt/seccomp/` by design; cannot blacklist `/run/firejail` (firejail needs it) |
| M4. /run/firejail state | **Acknowledged** | Same as M3 |
| M5. Nested firejail | **Mitigated** | `--nonewprivs` prevents privilege gain, `--restrict-namespaces` blocks new namespaces, `--join` blocked |
| M6. /var/log readable | **Acknowledged** | Low-value info leak; individual logs have restrictive perms |

---

## Summary

| Category | Tests | Blocked | Escaped/Leak | Notes |
|---|---|---|---|---|
| Credential access | 5 | 3 | **2** | OAuth tokens readable — by design (agent needs auth) |
| Network isolation | 4 | 1 | **3** | Full outbound — by design (agent needs API access) |
| /proc info leaks | 6 | 2 | **4** | mountinfo, environ, cmdline, cgroup |
| /sys info leaks | 4 | 2 | **2** | BTF, block devices |
| /run socket access | 7 | **5** | **2** | **FIXED:** snapd + systemd-notify blacklisted; firejail internals remain |
| Seccomp gaps | 5 | 2 | **3** | io_uring, memfd_create, userfaultfd (firejail 0.9.72 limitation) |
| Mount/namespace escape | 4 | 4 | 0 | --restrict-namespaces effective |
| /tmp isolation | 2 | **2** | 0 | **FIXED:** `--private-tmp` added |
| Firejail-specific | 4 | **3** | **1** | Nested firejail mitigated (nonewprivs); seccomp filter still readable |
| Signal injection | 2 | 2 | 0 | PID namespace + caps.drop effective |

**Overall: 43 tests, 26 blocked, 16 escaped/leaked, 1 partial**
**Post-remediation: 5 by-design, 8 info-leak (low impact), 3 seccomp gaps (firejail version)**

---

## CRITICAL Findings

### C1. Credential Exfiltration via OAuth Tokens + Open Network

**Severity: CRITICAL**
**Vector:** `~/.claude/.credentials.json` is readable (whitelisted `~/.claude`), and outbound network is fully open (no `--net=none`).

```
$ cat ~/.claude/.credentials.json
{"claudeAiOauth":{"accessToken":"sk-ant-oat01-qi5jvuT...","refreshToken":"sk-ant-ort01-N51VfI...",...}}

$ curl -s https://httpbin.org/get   # 200 OK
```

**Impact:** An agent (or injected code) can read the OAuth access token AND refresh token, then exfiltrate them over HTTPS to any external server. The refresh token allows persistent API access even after the session ends.

**Comparison:**
- **bwrap:** Same issue — `~/.claude` is writable and network is open. Credentials file is intentionally not blocked (agent needs it to authenticate).
- **Landlock:** Same issue — cannot block network, credentials readable.
- **Mitigation:** Use `--net=none` in firejail (but breaks agent's API access). Or use `--blacklist=$HOME/.claude/.credentials.json` and have the agent authenticate through a proxy.

### C2. Full Outbound Network Access (No Network Namespace Isolation)

**Severity: CRITICAL**
**Vector:** The firejail sandbox does NOT use `--net=none` or `--netfilter`. The network namespace is shared with the host (`net:[4026531840]`).

```
$ curl -s https://httpbin.org/get     # Works (HTTP 200)
$ nslookup google.com                 # DNS resolution works
$ python3 -c "import socket; s=socket.socket(AF_INET, SOCK_DGRAM); s.sendto(b'x',('8.8.8.8',53))"  # UDP works
```

**Impact:** Combined with C1, allows full credential exfiltration. Also enables:
- Data exfiltration of project files
- C2 communication
- Downloading and executing arbitrary payloads
- Lateral movement to internal network services

**Comparison:**
- **bwrap:** Same — no network isolation.
- **Landlock:** Same — Landlock LSM cannot restrict network at all.
- **All backends share this gap.** Network isolation requires `--net=none` (firejail), `--unshare-net` (bwrap), or eBPF/netfilter.

---

## HIGH Findings

### H1. io_uring Syscalls Not Blocked by Seccomp

**Severity: HIGH**
**Vector:** Firejail 0.9.72's default seccomp blacklist does not include `io_uring_setup` (425), `io_uring_enter` (426), or `io_uring_register` (427).

```python
# io_uring_setup returned -1, errno=14 (Bad address)
# io_uring NOT BLOCKED by seccomp!
```

**Impact:** io_uring provides a secondary path to perform file I/O that can bypass Landlock and some LSM checks. On kernels < 6.2, io_uring can bypass seccomp entirely for certain operations. This is a known attack surface for container escapes (CVE-2022-29582, CVE-2023-2598).

**Comparison:**
- **Landlock backend:** Blocks io_uring via custom seccomp-BPF filter — **better**.
- **bwrap:** Does not block io_uring either (same gap as firejail).

### H2. Snapd Socket Accessible (World-Writable)

**Severity: HIGH**
**Vector:** `/run/snapd.socket` and `/run/snapd-snap.socket` are world-writable Unix sockets, not blacklisted by the firejail backend.

```
$ curl --unix-socket /run/snapd.socket http://localhost/v2/system-info
# Returns full system info: kernel version, snap features, architecture, etc.

$ curl -X POST --unix-socket /run/snapd.socket http://localhost/v2/snaps/hello-world -d '{"action":"install"}'
# Returns 401 (login required) — but read-only APIs work without auth
```

**Impact:**
- Information disclosure: kernel version, snap confinement features, installed snaps
- Potential privilege escalation via snap install if polkit allows it (depends on system config)
- Snap interface manipulation

**Comparison:**
- **bwrap:** `/run` is replaced with tmpfs — snapd socket hidden. **Better.**
- **Landlock:** Cannot block Unix socket connect — same gap.
- **Fix:** Add `--blacklist=/run/snapd.socket --blacklist=/run/snapd-snap.socket` to firejail args.

### H3. systemd-notify Socket Accessible

**Severity: HIGH**
**Vector:** `/run/systemd/notify` is a world-executable (`srwxrwxrwx`) Unix socket accessible inside the sandbox.

```python
s = socket.socket(AF_UNIX, SOCK_DGRAM)
s.connect('/run/systemd/notify')  # Connected!
```

**Impact:** Can send `sd_notify` messages to systemd:
- `STOPPING=1` — trick systemd into thinking a service is stopping
- `WATCHDOG=1` — reset watchdog timers
- `READY=1` — fake service readiness
- Potential service disruption via spoofed notifications

**Comparison:**
- **bwrap:** `/run` is tmpfs — socket hidden. **Better.**
- **Landlock:** Cannot block — same gap.
- **Fix:** Add `--blacklist=/run/systemd/notify` to firejail args.

### H4. /tmp Not Isolated (Host /tmp Shared)

**Severity: HIGH**
**Vector:** Firejail does NOT use `--private-tmp`. The host's `/tmp` is fully readable and writable.

```
$ ls /tmp/
# Shows host /tmp contents including previous pentest artifacts,
# systemd private dirs, other users' temp files
```

**Impact:**
- **Cross-session data leakage:** Previous pentest artifacts visible (`/tmp/sandbox-pentest/`, `/tmp/test_seccomp.py`)
- **Symlink attacks:** Create symlinks in `/tmp` targeting files outside sandbox
- **Information disclosure:** systemd private temp dirs reveal service names
- **IPC channel:** `/tmp` can be used for covert communication between sandboxed and unsandboxed processes

**Comparison:**
- **bwrap:** Uses `--tmpfs /tmp` — fully isolated. **Better.**
- **Landlock:** /tmp is writable (same gap — cannot hide, only restrict).
- **Fix:** Add `--private-tmp` to firejail args.

---

## MEDIUM Findings

### M1. /proc/self/environ Readable (Full Environment Dump)

**Severity: MEDIUM**
**Vector:** `/proc/self/environ` is readable and reveals all environment variables including sandbox configuration.

```
$ cat /proc/self/environ | tr '\0' '\n'
SANDBOX_ACTIVE=1
SANDBOX_BACKEND=firejail
SANDBOX_PROJECT_DIR=/home/dotto.linux/agent_container
container=firejail
...
```

**Impact:** Reveals sandbox technology (`container=firejail`), project directory, and any environment variables not scrubbed by the blocklist. The `container=firejail` variable is set by firejail itself and cannot be blocked.

**Comparison:**
- **bwrap:** Same — `/proc/self/environ` readable.
- **Landlock:** Same.

### M2. /proc/self/mountinfo Reveals Full Mount Topology

**Severity: MEDIUM**
**Vector:** `/proc/self/mountinfo` is readable and reveals the complete mount namespace layout.

```
$ cat /proc/self/mountinfo
# Shows all 50+ mounts including:
# - /dev/vda1 (disk device names)
# - virtiofs mount on /Users/dotto (macOS host share path)
# - Firejail internal mounts (/run/firejail/*)
# - All whitelisted paths
```

**Impact:**
- Reveals host filesystem structure and device names
- Reveals macOS host mount (`/Users/dotto` via virtiofs) — platform fingerprinting
- Reveals exact sandbox configuration (which paths whitelisted/blacklisted)
- Attacker can identify the weakest points in the mount layout

**Comparison:**
- **bwrap:** Same info leak through `/proc/self/mountinfo`.
- **Landlock:** No mount namespace — no mountinfo leak, but paths return EACCES which is also informative.

### M3. Firejail Seccomp Filter Binary Readable

**Severity: MEDIUM**
**Vector:** `/run/firejail/mnt/seccomp/` contains the compiled BPF programs and is readable.

```
$ ls -la /run/firejail/mnt/seccomp/
seccomp           40 bytes  (main filter)
seccomp.32       432 bytes  (32-bit filter)
seccomp.list     127 bytes  (filter file list)
seccomp.namespaces 184 bytes (namespace filter)
```

**Impact:** An attacker can download and reverse-engineer the exact seccomp BPF program to identify which syscalls are allowed. This makes it trivial to find seccomp gaps (like io_uring).

**Comparison:**
- **bwrap:** Seccomp filters not exposed in filesystem.
- **Landlock:** Custom seccomp compiled at runtime, not persisted to disk.
- **Fix:** Firejail exposes these by design — cannot easily fix without patching firejail.

### M4. /run/firejail Internal State Accessible

**Severity: MEDIUM**
**Vector:** `/run/firejail/mnt/` contains sandbox configuration files readable by the sandboxed process.

```
$ cat /run/firejail/mnt/join       # "1" — join is disabled
$ cat /run/firejail/mnt/nonewprivs # ""
$ cat /run/firejail/mnt/groups     # ""
$ cat /run/firejail/mnt/fslogger   # Full filesystem access log
```

**Impact:** Reveals sandbox configuration, join status, and the `fslogger` contains a complete record of filesystem access patterns — useful for mapping the sandbox's structure.

### M5. Nested Firejail Execution Possible

**Severity: MEDIUM**
**Vector:** Despite `--restrict-namespaces`, firejail can be executed inside the sandbox.

```
$ firejail --noprofile -- echo "nested firejail works"
nested firejail works
```

**Impact:** Nested firejail execution could potentially:
- Override seccomp filters (the inner sandbox may have fewer restrictions)
- Create confusion about which sandbox layer is active
- Historically, `firejail --join` has been exploitable (CVE-2022-31214)

**Note:** `--restrict-namespaces` prevents the nested instance from creating *new* namespaces, and `--caps.drop=all` limits capabilities. The `--join` vector appears blocked (`--shell=none` configured). Risk is limited but the attack surface is unnecessary.

**Comparison:**
- **bwrap:** bwrap binary accessible but userns creation blocked (can't run bwrap inside bwrap unless userns allowed).
- **Landlock:** Cannot run firejail inside Landlock (setuid blocked by `NO_NEW_PRIVS`).
- **Fix:** `--blacklist=/usr/bin/firejail` or `--private-bin` to restrict available binaries.

### M6. /var/log Partially Readable

**Severity: MEDIUM**
**Vector:** `/var/log/` directory listing is accessible. Individual log files have restrictive permissions, but the directory structure reveals installed services.

```
$ ls /var/log/
apt  btmp  dist-upgrade  journal  landscape  munge  private
```

**Impact:** Service enumeration — reveals munge (Slurm), landscape (Canonical management), apt history.

**Comparison:**
- **bwrap:** `/var` can be restricted. Current config mounts it read-only but visible.
- **Landlock:** Same visibility.

---

## LOW Findings

### L1. /sys Information Disclosure

**Severity: LOW**
**Vector:** `/sys/kernel/btf/`, `/sys/class/block/`, `/sys/kernel/kexec_loaded` are readable.

**Impact:**
- BTF (BPF Type Format) data reveals kernel module names and types
- Block device enumeration (`vda`, `vda1`, `vda15`, `vda16`, `vdb`) reveals disk layout
- `kexec_loaded` reveals whether a kexec kernel is staged

**Comparison:**
- **bwrap:** Same — `/sys` generally accessible.
- **Landlock:** Same.

### L2. /proc/1/cmdline Reveals Full Sandbox Configuration

**Severity: LOW**
**Vector:** PID 1 inside the sandbox is the firejail process. Its `/proc/1/cmdline` reveals the complete command line.

```
$ cat /proc/1/cmdline | tr '\0' ' '
firejail --noprofile --quiet --caps.drop=all --nonewprivs --seccomp --nogroups
  --nosound --no3d --restrict-namespaces --read-only=/usr ...
  --whitelist=/home/dotto.linux/.claude ...
  -- claude --dangerously-skip-permissions
```

**Impact:** Complete sandbox configuration visible, including all whitelisted/blacklisted paths and the launched command. Reveals `--dangerously-skip-permissions` flag usage.

**Comparison:**
- **bwrap:** PID 1 is the sandboxed process (bwrap execs), so cmdline shows the user's command only.
- **Landlock:** No PID namespace — can see all host processes (worse in different way).

### L3. /etc/passwd Filtering (Documented, Fixed Here)

**Severity: LOW (informational)**
**Status:** The known UID filtering issue is **mitigated** on this system — slurm user has UID 120 (system range).

```
$ grep slurm /etc/passwd
slurm:x:120:120::/nonexistent:/usr/sbin/nologin
```

### L4. `container=firejail` Environment Variable

**Severity: LOW**
**Vector:** Firejail automatically sets `container=firejail` in the environment. This cannot be prevented by the sandbox configuration.

**Impact:** Any process can detect it's running inside firejail and potentially adjust behavior (e.g., malware may go dormant).

---

## Comparison with bwrap and Landlock Backends

| Attack Vector | Firejail | bwrap | Landlock |
|---|---|---|---|
| **Credential exfiltration** | VULNERABLE | VULNERABLE | VULNERABLE |
| **Network isolation** | NOT ISOLATED | NOT ISOLATED | NOT ISOLATED |
| **io_uring bypass** | NOT BLOCKED | NOT BLOCKED | BLOCKED |
| **memfd_create** | NOT BLOCKED | NOT BLOCKED | BLOCKED |
| **userfaultfd** | NOT BLOCKED | NOT BLOCKED | BLOCKED |
| **/tmp isolation** | NOT ISOLATED | ISOLATED (tmpfs) | NOT ISOLATED |
| **snapd socket** | ACCESSIBLE | HIDDEN (tmpfs /run) | ACCESSIBLE |
| **systemd-notify** | ACCESSIBLE | HIDDEN (tmpfs /run) | ACCESSIBLE |
| **/run isolation** | PARTIAL (blacklist) | FULL (tmpfs + whitelist) | NONE |
| **Seccomp filter leak** | READABLE | NOT EXPOSED | NOT EXPOSED |
| **Nested sandbox** | POSSIBLE | BLOCKED (no userns) | BLOCKED (no_new_privs) |
| **PID namespace** | YES | YES | NO |
| **Mount namespace** | YES | YES | NO |
| **Unix socket blocking** | YES (mount ns) | YES (mount ns) | NO |
| **Self-protection** | PARTIAL | FULL (ro-bind) | WEAK |
| **Process visibility** | ISOLATED | ISOLATED | HOST VISIBLE |

### Backend Ranking (Security)

1. **bwrap** — Strongest: full /run isolation via tmpfs, /tmp isolation, no exposed internals
2. **Firejail** — Middle: mount namespace provides hiding, but /run blacklist is incomplete, /tmp shared, seccomp weaker than Landlock's custom filter
3. **Landlock** — Weakest namespace isolation: no mount ns (can't hide paths or block sockets), but strongest seccomp (custom BPF blocks io_uring, memfd_create, userfaultfd)

### Ideal: Firejail + Landlock's Seccomp

Firejail's mount namespace (hiding paths, socket blocking) combined with Landlock's custom seccomp filter (io_uring, memfd_create blocking) would provide the strongest isolation.

---

## Recommendations

### Immediate (Configuration Changes)

1. **Add `--private-tmp`** to firejail args — isolates /tmp
2. **Blacklist additional /run paths:**
   ```bash
   --blacklist=/run/snapd.socket
   --blacklist=/run/snapd-snap.socket
   --blacklist=/run/systemd/notify
   --blacklist=/run/lxd-installer.socket
   ```
3. **Blacklist firejail binary inside sandbox:**
   ```bash
   --blacklist=/usr/bin/firejail
   ```
4. **Consider `--blacklist=/run/firejail`** to hide internal state

### Medium-Term

5. **Add custom seccomp filter** to block io_uring, memfd_create, userfaultfd, process_vm_readv/writev (match Landlock backend's filter)
6. **Evaluate `--net=none`** — breaks agent API access but eliminates exfiltration. Consider `--netfilter` with restrictive rules instead.
7. **Add `--private-bin`** to restrict available binaries (reduces attack surface)

### Long-Term

8. **Network policy:** Use `--netfilter` with iptables rules allowing only the Anthropic API endpoint
9. **Credential isolation:** Proxy agent authentication through a credential broker outside the sandbox
10. **Upgrade firejail** — version 0.9.72 is from April 2024; newer versions may address seccomp gaps
