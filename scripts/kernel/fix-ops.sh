#!/bin/bash
# fix-ops.sh — restore ops_fstype.c and add lock_etcd registration
set -e
SRC=$(echo ~/rpmbuild/BUILD/kernel-*/linux-*/)
GFS2=$SRC/fs/gfs2

# Restore original from SRPM tarball
cd /tmp
if [[ ! -f linux-6.18.35.tar.xz ]]; then
    dnf download --source kernel6.18 2>/dev/null
    rpm2cpio kernel6.18*.src.rpm | cpio -idmv linux-6.18.35.tar.xz 2>/dev/null
fi
tar xf linux-6.18.35.tar.xz linux-6.18.35/fs/gfs2/ops_fstype.c 2>/dev/null
cp linux-6.18.35/fs/gfs2/ops_fstype.c "$GFS2/"
rm -rf linux-6.18.35
echo "Restored original ops_fstype.c"

cd "$GFS2"

# Add extern before the lock_nolock if-block (2 lines above "if (!strcmp")
LINE=$(grep -n 'if (!strcmp("lock_nolock"' ops_fstype.c | head -1 | cut -d: -f1)
sed -i "${LINE}i#ifdef CONFIG_GFS2_FS_LOCKING_ETCD\nextern const struct lm_lockops letcd_ops;\n#endif\n" ops_fstype.c
echo "Added extern declaration"

# Add else-if block after lock_dlm's #endif
# Find the #endif that closes lock_dlm (first #endif after "lock_dlm")
ENDIF=$(grep -n "lock_dlm" ops_fstype.c | head -1 | cut -d: -f1)
ENDIF=$(tail -n +$ENDIF ops_fstype.c | grep -n "^#endif" | head -1 | cut -d: -f1)
ENDIF=$((ENDIF + $(grep -n "lock_dlm" ops_fstype.c | head -1 | cut -d: -f1) - 1))
sed -i "${ENDIF}a#ifdef CONFIG_GFS2_FS_LOCKING_ETCD\n\t} else if (!strcmp(\"lock_etcd\", proto)) {\n\t\tlm = \&letcd_ops;\n#endif" ops_fstype.c
echo "Added lock_etcd else-if"

# Verify
echo "=== Result ==="
grep -n -B1 -A2 "lock_etcd\|lock_dlm\|lock_nolock" ops_fstype.c | grep -v "^[0-9]*--$"
