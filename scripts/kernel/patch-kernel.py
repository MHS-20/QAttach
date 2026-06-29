#!/usr/bin/env python3
"""
patch-kernel.py — apply lock_etcd patches to GFS2 kernel sources.

Patches fs/gfs2/main.c and fs/gfs2/ops_fstype.c in the kernel source
tree to register the lock_etcd protocol.

Usage: python3 patch-kernel.py <path-to-kernel-source>
"""

import sys, os

GFS2 = os.path.join(sys.argv[1], 'fs/gfs2')

def patch_main(path):
    with open(path) as f:
        content = f.read()
    orig = content

    # Add extern declarations after the top-level comment block (first */)
    idx = content.index('*/')
    content = (content[:idx+2] +
               '\nextern int lock_etcd_init_module(void);\n' +
               'extern void lock_etcd_exit_module(void);\n' +
               content[idx+2:])

    # Insert call in init_gfs2_fs before return 0
    content = content.replace(
        'pr_info("GFS2 installed\\n");\n\n\treturn 0;',
        'pr_info("GFS2 installed\\n");\n\tlock_etcd_init_module();\n\n\treturn 0;')

    # Insert call in exit_gfs2_fs
    content = content.replace(
        '\n\tunregister_filesystem(&gfs2_fs_type);',
        '\n\tlock_etcd_exit_module();\n\tunregister_filesystem(&gfs2_fs_type);')

    if content == orig:
        print(f'{path}: already patched, skipping')
        return
    with open(path, 'w') as f:
        f.write(content)
    print(f'{path}: patched')

def patch_ops(path):
    with open(path) as f:
        content = f.read()
    orig = content

    # Add extern + else-if for lock_etcd
    content = content.replace(
        '\tif (!strcmp("lock_nolock", proto)) {',
        '#ifdef CONFIG_GFS2_FS_LOCKING_ETCD\n'
        'extern const struct lm_lockops letcd_ops;\n'
        '#endif\n'
        '\tif (!strcmp("lock_nolock", proto)) {')

    content = content.replace(
        '#ifdef CONFIG_GFS2_FS_LOCKING_DLM\n'
        '\t} else if (!strcmp("lock_dlm", proto)) {\n'
        '\t\tlm = &gfs2_dlm_ops;\n'
        '#endif',
        '#ifdef CONFIG_GFS2_FS_LOCKING_DLM\n'
        '\t} else if (!strcmp("lock_dlm", proto)) {\n'
        '\t\tlm = &gfs2_dlm_ops;\n'
        '#endif\n'
        '#ifdef CONFIG_GFS2_FS_LOCKING_ETCD\n'
        '\t} else if (!strcmp("lock_etcd", proto)) {\n'
        '\t\tlm = &letcd_ops;\n'
        '#endif')

    if content == orig:
        print(f'{path}: already patched, skipping')
        return
    with open(path, 'w') as f:
        f.write(content)
    print(f'{path}: patched')

if __name__ == '__main__':
    patch_main(os.path.join(GFS2, 'main.c'))
    patch_ops(os.path.join(GFS2, 'ops_fstype.c'))
