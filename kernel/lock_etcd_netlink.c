/* SPDX-License-Identifier: GPL-2.0-only */
#define pr_fmt(fmt) "lock_etcd: " fmt
#include <linux/netlink.h>
#include <net/netlink.h>
#include <linux/skbuff.h>
#include "lock_etcd_internal.h"

struct sock *letcd_nl_sk;
EXPORT_SYMBOL(letcd_nl_sk);

/* ---- dispatch helpers ---- */

static void dispatch_mount_resp(struct letcd_mount_resp *resp)
{
	unsigned long flags;

	spin_lock_irqsave(&letcd_mount_ctx.lock, flags);
	letcd_mount_ctx.mount_jid = resp->jid;
	letcd_mount_ctx.mount_error = (resp->jid < 0) ? resp->jid : 0;
	spin_unlock_irqrestore(&letcd_mount_ctx.lock, flags);
	complete(&letcd_mount_ctx.mount_done);
}

static void dispatch_lock_grant(struct letcd_lock_grant *grant)
{
	struct gfs2_glock *gl = letcd_pending_remove(grant->request_id);
	if (!gl)
		return;
	letcd_revision_set(gl, grant->etcd_revision);
	gfs2_glock_complete(gl, gl->gl_req);
}

static void dispatch_lock_deny(struct letcd_lock_deny *deny)
{
	struct gfs2_glock *gl = letcd_pending_remove(deny->request_id);
	int ret = -EIO;

	if (!gl)
		return;
	if (deny->reason == LETCD_DENY_STALE)
		ret = -ESTALE;
	else if (deny->reason == LETCD_DENY_CONTENDED)
		ret = -EAGAIN;
	gfs2_glock_complete(gl, ret);
}

static void dispatch_lock_wait(struct letcd_lock_wait *wait)
{
	struct gfs2_glock *gl = letcd_pending_remove(wait->request_id);
	if (!gl)
		return;
	letcd_pending_insert(wait->request_id, gl);
}

static void dispatch_bast(struct letcd_bast *bast)
{
	struct gfs2_glock *gl;

	gl = letcd_bast_lookup(bast->glock_type, bast->glock_number);
	if (!gl)
		return;
	gfs2_glock_cb(gl, bast->target_mode);
}

static void dispatch_recovery_ok(struct letcd_recovery_ok *rok)
{
	pr_info("recovery ok: jid=%u\n", rok->jid);
}

/* ---- netlink recv ---- */

static void letcd_nl_recv(struct sk_buff *skb)
{
	struct nlmsghdr *nlh = nlmsg_hdr(skb);
	void *payload = nlmsg_data(nlh);
	size_t plen = nlmsg_len(nlh);

	/* Store agent PID on first REGISTER message */
	if (nlh->nlmsg_type == LETCD_MSG_REGISTER && !agent_pid) {
		agent_pid = NETLINK_CB(skb).portid;
		pr_info("agent registered pid=%u\n", agent_pid);
		return;
	}

	if (plen < 4)
		return;

	switch (*(u32 *)payload) {
	case LETCD_MSG_LOCK_GRANT:
		if (plen >= 4 + sizeof(struct letcd_lock_grant))
			dispatch_lock_grant(payload + 4);
		break;
	case LETCD_MSG_LOCK_DENY:
		if (plen >= 4 + sizeof(struct letcd_lock_deny))
			dispatch_lock_deny(payload + 4);
		break;
	case LETCD_MSG_LOCK_WAIT:
		if (plen >= 4 + sizeof(struct letcd_lock_wait))
			dispatch_lock_wait(payload + 4);
		break;
	case LETCD_MSG_BAST:
		if (plen >= 4 + sizeof(struct letcd_bast))
			dispatch_bast(payload + 4);
		break;
	case LETCD_MSG_RECOVERY_OK:
		if (plen >= 4 + sizeof(struct letcd_recovery_ok))
			dispatch_recovery_ok(payload + 4);
		break;
	case LETCD_MSG_MOUNT_RESP:
		if (plen >= 4 + sizeof(struct letcd_mount_resp))
			dispatch_mount_resp(payload + 4);
		break;
	}
}

/* ---- agent PID tracking ---- */

static u32 agent_pid;

/* ---- create / destroy ---- */

int letcd_netlink_init(void)
{
	struct netlink_kernel_cfg cfg = { .input = letcd_nl_recv };

	agent_pid = 0;
	letcd_nl_sk = netlink_kernel_create(&init_net, LETCD_NETLINK_FAMILY,
					    &cfg);
	if (!letcd_nl_sk) {
		pr_err("netlink_kernel_create failed\n");
		return -ENOMEM;
	}
	return 0;
}

void letcd_netlink_exit(void)
{
	if (letcd_nl_sk) {
		netlink_kernel_release(letcd_nl_sk);
		letcd_nl_sk = NULL;
	}
}

/* ---- send ---- */

int letcd_nl_send_msg(int msg_type, const void *payload, size_t payload_len)
{
	struct sk_buff *skb;
	struct nlmsghdr *nlh;

	if (!letcd_nl_sk)
		return -ENODEV;
	if (!agent_pid) {
		pr_debug("no agent pid registered yet\n");
		return -ENODEV;
	}

	skb = nlmsg_new(NLMSG_HDRLEN + payload_len, GFP_ATOMIC);
	if (!skb)
		return -ENOMEM;

	nlh = nlmsg_put(skb, 0, 0, msg_type, payload_len, 0);
	if (!nlh) {
		nlmsg_free(skb);
		return -EMSGSIZE;
	}
	memcpy(nlmsg_data(nlh), payload, payload_len);
	return nlmsg_unicast(letcd_nl_sk, skb, agent_pid);
}
EXPORT_SYMBOL(letcd_nl_send_msg);
