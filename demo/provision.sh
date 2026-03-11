#!/bin/bash
# provision.sh — Set up Slurm + LDAP demo VM for sandbox testing
#
# Run as root (called by Lima provisioning or manually: sudo bash provision.sh)
#
# What this sets up:
#   - Single-node Slurm cluster with accounting (MariaDB + slurmdbd)
#   - LDAP directory (slapd) with demo users (alice, bob, carol)
#   - NSS integration so getent passwd shows LDAP users
#   - bubblewrap, firejail (all three sandbox backends)
#   - Landlock available via kernel 6.8+
#   - NO admin hardening (no eBPF, no job submit plugin, no wrappers)

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Error: run as root (sudo bash $0)" >&2
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive

echo "── Installing packages ──────────────────────────────────────"
apt-get update
apt-get install -y \
    bubblewrap \
    firejail \
    munge \
    slurm-wlm \
    slurm-client \
    slurmctld \
    slurmd \
    slurmdbd \
    mariadb-server \
    slapd \
    ldap-utils \
    libnss-ldapd \
    libpam-ldapd \
    nscd \
    nslcd \
    python3 \
    strace \
    tmux \
    jq \
    git \
    curl

# ── Allow bwrap (AppArmor on Ubuntu 24.04 blocks user namespaces) ──
echo "── Allowing bwrap through AppArmor ────────────────────────────"
BWRAP_PATH=$(command -v bwrap)
if [[ -n "$BWRAP_PATH" ]] && aa-status &>/dev/null; then
    # Create an AppArmor profile that allows bwrap unrestricted access
    cat > /etc/apparmor.d/bwrap-allow << APPARMOR
abi <abi/4.0>,
include <tunables/global>

profile bwrap $BWRAP_PATH flags=(unconfined) {
  userns,
}
APPARMOR
    apparmor_parser -r /etc/apparmor.d/bwrap-allow 2>/dev/null || true
fi

# ── MariaDB for Slurm accounting ──────────────────────────────
echo "── Setting up MariaDB ───────────────────────────────────────"
systemctl enable --now mariadb
mysql -e "CREATE DATABASE IF NOT EXISTS slurm_acct_db;"
mysql -e "CREATE USER IF NOT EXISTS 'slurm'@'localhost' IDENTIFIED BY 'slurmdbpass';"
mysql -e "GRANT ALL ON slurm_acct_db.* TO 'slurm'@'localhost';"
mysql -e "FLUSH PRIVILEGES;"

# ── Munge ──────────────────────────────────────────────────────
echo "── Setting up Munge ─────────────────────────────────────────"
if [[ ! -f /etc/munge/munge.key ]]; then
    dd if=/dev/urandom of=/etc/munge/munge.key bs=1024 count=1
    chown munge:munge /etc/munge/munge.key
    chmod 400 /etc/munge/munge.key
fi
systemctl enable --now munge

# ── Slurm configuration ───────────────────────────────────────
echo "── Configuring Slurm ────────────────────────────────────────"
HOSTNAME=$(hostname -s)
CPUS=$(nproc)
MEM=$(free -m | awk '/Mem:/{print int($2*0.9)}')

cat > /etc/slurm/slurm.conf << 'EOF'
ClusterName=demo
SlurmctldHost=HOSTNAME_PLACEHOLDER

MpiDefault=none
ProctrackType=proctrack/linuxproc
ReturnToService=2
SlurmctldPidFile=/run/slurmctld.pid
SlurmdPidFile=/run/slurmd.pid
SlurmdSpoolDir=/var/spool/slurmd
SlurmUser=slurm
StateSaveLocation=/var/spool/slurmctld
SwitchType=switch/none
TaskPlugin=task/none

# Scheduling
SchedulerType=sched/backfill
SelectType=select/cons_tres

# Accounting
AccountingStorageType=accounting_storage/slurmdbd
AccountingStorageHost=localhost
JobAcctGatherType=jobacct_gather/linux

# Logging
SlurmctldLogFile=/var/log/slurm/slurmctld.log
SlurmdLogFile=/var/log/slurm/slurmd.log

# Compute node (this VM)
NodeName=HOSTNAME_PLACEHOLDER CPUs=CPUS_PLACEHOLDER RealMemory=MEM_PLACEHOLDER State=UNKNOWN
PartitionName=debug Nodes=ALL Default=YES MaxTime=INFINITE State=UP
EOF

sed -i "s/HOSTNAME_PLACEHOLDER/$HOSTNAME/g" /etc/slurm/slurm.conf
sed -i "s/CPUS_PLACEHOLDER/$CPUS/g" /etc/slurm/slurm.conf
sed -i "s/MEM_PLACEHOLDER/$MEM/g" /etc/slurm/slurm.conf

cat > /etc/slurm/slurmdbd.conf << 'EOF'
DbdHost=localhost
DbdPort=6819
SlurmUser=slurm
StorageType=accounting_storage/mysql
StorageHost=localhost
StorageUser=slurm
StoragePass=slurmdbpass
StorageLoc=slurm_acct_db
LogFile=/var/log/slurm/slurmdbd.log
PidFile=/run/slurmdbd.pid
EOF

chown slurm:slurm /etc/slurm/slurmdbd.conf
chmod 600 /etc/slurm/slurmdbd.conf

mkdir -p /var/spool/slurmctld /var/spool/slurmd /var/log/slurm
chown slurm:slurm /var/spool/slurmctld /var/log/slurm
chown root:root /var/spool/slurmd

systemctl enable --now slurmdbd
sleep 2
systemctl enable --now slurmctld
systemctl enable --now slurmd

# Create cluster and default account
sacctmgr -i add cluster demo 2>/dev/null || true
sacctmgr -i add account default Description="Default" Organization="Demo" 2>/dev/null || true

# ── LDAP (slapd) ──────────────────────────────────────────────
echo "── Configuring LDAP ─────────────────────────────────────────"
debconf-set-selections << 'EOF'
slapd slapd/internal/adminpw password admin
slapd slapd/internal/generated_adminpw password admin
slapd slapd/password1 password admin
slapd slapd/password2 password admin
slapd slapd/domain string demo.local
slapd shared/organization string Demo
slapd slapd/purge_database boolean true
slapd slapd/move_old_database boolean true
EOF
dpkg-reconfigure -f noninteractive slapd

# Add OUs and demo users
ldapadd -x -D "cn=admin,dc=demo,dc=local" -w admin << 'EOF'
dn: ou=People,dc=demo,dc=local
objectClass: organizationalUnit
ou: People

dn: ou=Groups,dc=demo,dc=local
objectClass: organizationalUnit
ou: Groups

dn: cn=researchers,ou=Groups,dc=demo,dc=local
objectClass: posixGroup
cn: researchers
gidNumber: 2000
memberUid: alice
memberUid: bob
memberUid: carol

dn: uid=alice,ou=People,dc=demo,dc=local
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
uid: alice
sn: Researcher
givenName: Alice
cn: Alice Researcher
displayName: Alice Researcher
uidNumber: 2001
gidNumber: 2000
userPassword: password
loginShell: /bin/bash
homeDirectory: /home/alice

dn: uid=bob,ou=People,dc=demo,dc=local
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
uid: bob
sn: Analyst
givenName: Bob
cn: Bob Analyst
displayName: Bob Analyst
uidNumber: 2002
gidNumber: 2000
userPassword: password
loginShell: /bin/bash
homeDirectory: /home/bob

dn: uid=carol,ou=People,dc=demo,dc=local
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
uid: carol
sn: Engineer
givenName: Carol
cn: Carol Engineer
displayName: Carol Engineer
uidNumber: 2003
gidNumber: 2000
userPassword: password
loginShell: /bin/bash
homeDirectory: /home/carol
EOF

# Create home directories for LDAP users
for user in alice bob carol; do
    mkdir -p /home/$user
    # Use numeric IDs in case NSS isn't configured yet
    case $user in
        alice) chown 2001:2000 /home/$user ;;
        bob)   chown 2002:2000 /home/$user ;;
        carol) chown 2003:2000 /home/$user ;;
    esac
done

# ── nslcd (LDAP NSS client) ───────────────────────────────────
echo "── Configuring NSS/LDAP ─────────────────────────────────────"
cat > /etc/nslcd.conf << 'EOF'
uid nslcd
gid nslcd
uri ldap://127.0.0.1/
base dc=demo,dc=local
base passwd ou=People,dc=demo,dc=local
base group ou=Groups,dc=demo,dc=local
EOF

# Configure NSS to use LDAP
sed -i 's/^passwd:.*/passwd:         files ldap/' /etc/nsswitch.conf
sed -i 's/^group:.*/group:          files ldap/' /etc/nsswitch.conf
sed -i 's/^shadow:.*/shadow:         files ldap/' /etc/nsswitch.conf

systemctl restart nslcd
systemctl restart nscd

# ── Add users to Slurm accounting ─────────────────────────────
echo "── Adding Slurm users ───────────────────────────────────────"
# Lima's default user
DEFAULT_USER=$(getent passwd 501 2>/dev/null | cut -d: -f1 || ls /home/ | grep -v -E '^(alice|bob|carol)$' | head -1)
if [[ -n "$DEFAULT_USER" ]]; then
    sacctmgr -i add user "$DEFAULT_USER" Account=default 2>/dev/null || true
fi
# LDAP users
for user in alice bob carol; do
    sacctmgr -i add user "$user" Account=default 2>/dev/null || true
done

# ── Summary ───────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  Demo VM provisioned!"
echo ""
echo "  Slurm:     sinfo / squeue / sbatch / sacct"
echo "  LDAP:      getent passwd  (should show alice, bob, carol)"
echo "  Backends:  bubblewrap $(bwrap --version 2>&1 | head -1)"
echo "             firejail $(firejail --version 2>&1 | head -1)"
echo "             landlock (kernel $(uname -r))"
echo ""
echo "  No admin hardening applied."
echo "  Install sandbox:  cd ~/gits/agent_container && ./install.sh"
echo "══════════════════════════════════════════════════════════════"
