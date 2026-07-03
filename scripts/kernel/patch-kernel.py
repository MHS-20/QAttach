#!/usr/bin/env python3
"""
patch-kernel.py — apply lock_etcd patches to GFS2 kernel sources.

Patches fs/gfs2/main.c and fs/gfs2/ops_fstype.c in the kernel source
tree to register the lock_etcd protocol, and adds glock state debug
logging to fs/gfs2/glock.c.

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

def patch_glock(path):
    """Add glock state debug logging to gfs2_glock_nq, glock_work_func, and __gfs2_holder_init."""
    with open(path) as f:
        content = f.read()
    orig = content

    # Log at start of gfs2_glock_nq: int gfs2_glock_nq(struct gfs2_holder *gh)
    old = ('int gfs2_glock_nq(struct gfs2_holder *gh)\n'
           '{\n'
           '\tstruct gfs2_glock *gl = gh->gh_gl;\n')
    new = ('int gfs2_glock_nq(struct gfs2_holder *gh)\n'
           '{\n'
           '\tstruct gfs2_glock *gl = gh->gh_gl;\n'
           '\tpr_info("glock_nq: t=%u n=%llu mode=%u fl=%#lx glst=%u gltgt=%u hflags=%#x\\n",\n'
           '\t\tgl->gl_name.ln_type, gl->gl_name.ln_number,\n'
           '\t\tgh->gh_state, gl->gl_flags, gl->gl_state,\n'
           '\t\tgl->gl_target, gh->gh_flags);\n')
    if old in content:
        content = content.replace(old, new, 1)
        print(f'{path}: gfs2_glock_nq debug inserted')
    else:
        print(f'{path}: WARNING — gfs2_glock_nq not found')

    # Log at start of glock_work_func
    old2 = ('static void glock_work_func(struct work_struct *work)\n'
            '{\n'
            '\tunsigned long delay = 0;\n'
            '\tstruct gfs2_glock *gl = container_of(work, struct gfs2_glock, gl_work.work);\n')
    new2 = ('static void glock_work_func(struct work_struct *work)\n'
            '{\n'
            '\tunsigned long delay = 0;\n'
            '\tstruct gfs2_glock *gl = container_of(work, struct gfs2_glock, gl_work.work);\n'
            '\t{ unsigned int _hc = 0; struct gfs2_holder *_h;\n'
            '\t  list_for_each_entry(_h, &gl->gl_holders, gh_list) _hc++;\n'
            '\t  pr_info("glock_work: t=%u n=%llu glst=%u gltgt=%u fl=%#lx hldrs=%u\\n",\n'
            '\t    gl->gl_name.ln_type, gl->gl_name.ln_number,\n'
            '\t    gl->gl_state, gl->gl_target, gl->gl_flags, _hc); }\n')
    if old2 in content:
        content = content.replace(old2, new2, 1)
        print(f'{path}: glock_work_func debug inserted')
    else:
        print(f'{path}: WARNING — glock_work_func not found')

    # Log at start of __gfs2_holder_init — catches ALL holder inits
    old3 = ('void __gfs2_holder_init(struct gfs2_glock *gl, unsigned int state, u16 flags,\n'
            '\t\t\tstruct gfs2_holder *gh, unsigned long ip)\n'
            '{\n')
    new3 = ('void __gfs2_holder_init(struct gfs2_glock *gl, unsigned int state, u16 flags,\n'
            '\t\t\tstruct gfs2_holder *gh, unsigned long ip)\n'
            '{\n'
            '\tpr_info("holder_init: t=%u n=%llu state=%u flags=%#x ip=%#lx\\n",\n'
            '\t\tgl->gl_name.ln_type, gl->gl_name.ln_number, state, flags, ip);\n')
    if old3 in content:
        content = content.replace(old3, new3, 1)
        print(f'{path}: __gfs2_holder_init debug inserted')
    else:
        print(f'{path}: WARNING — __gfs2_holder_init not found')

    if content == orig:
        print(f'{path}: nothing changed')
        return
    with open(path, 'w') as f:
        f.write(content)

def patch_inode(path):
    """Add debug to gfs2_setattr to log which glock it locks."""
    with open(path) as f:
        content = f.read()
    orig = content

    # Log right before gfs2_glock_nq_init in gfs2_setattr
    old = ('\terror = gfs2_glock_nq_init(ip->i_gl, LM_ST_EXCLUSIVE, 0, &i_gh);\n'
           '\tif (error)\n'
           '\t\tgoto out;')
    new = ('\tpr_info("setattr: t=%u n=%llu glst=%u gltgt=%u fl=%#lx\\n",\n'
           '\t\tip->i_gl->gl_name.ln_type, ip->i_gl->gl_name.ln_number,\n'
           '\t\tip->i_gl->gl_state, ip->i_gl->gl_target, ip->i_gl->gl_flags);\n'
           '\terror = gfs2_glock_nq_init(ip->i_gl, LM_ST_EXCLUSIVE, 0, &i_gh);\n'
           '\tif (error)\n'
           '\t\tgoto out;')
    if old in content:
        content = content.replace(old, new, 1)
        print(f'{path}: gfs2_setattr debug inserted')
    else:
        print(f'{path}: WARNING — setattr pattern not found')

    # Also in gfs2_setattr_simple (for completeness)
    old2 = ('\tif (gfs2_glock_is_locked_by_me(ip->i_gl) == NULL) {\n'
            '\t\terror = gfs2_glock_nq_init(ip->i_gl, LM_ST_SHARED, LM_FLAG_ANY, &gh);')
    new2 = ('\tif (gfs2_glock_is_locked_by_me(ip->i_gl) == NULL) {\n'
            '\t\tpr_info(\"setattr_simple: t=%u n=%llu glst=%u fl=%#lx\\n\",\n'
            '\t\t\tip->i_gl->gl_name.ln_type, ip->i_gl->gl_name.ln_number,\n'
            '\t\t\tip->i_gl->gl_state, ip->i_gl->gl_flags);\n'
            '\t\terror = gfs2_glock_nq_init(ip->i_gl, LM_ST_SHARED, LM_FLAG_ANY, &gh);')
    if old2 in content:
        content = content.replace(old2, new2, 1)
        print(f'{path}: setattr_simple debug inserted')

    if content == orig:
        print(f'{path}: nothing changed')
        return
    with open(path, 'w') as f:
        f.write(content)

if __name__ == '__main__':
    patch_main(os.path.join(GFS2, 'main.c'))
    patch_ops(os.path.join(GFS2, 'ops_fstype.c'))
    patch_glock(os.path.join(GFS2, 'glock.c'))
    patch_inode(os.path.join(GFS2, 'inode.c'))
