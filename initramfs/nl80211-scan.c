// SPDX-License-Identifier: GPL-2.0-only
#include <errno.h>
#include <linux/genetlink.h>
#include <linux/netlink.h>
#include <linux/nl80211.h>
#include <net/if.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <unistd.h>

#ifndef NLA_ALIGNTO
#define NLA_ALIGNTO 4
#endif
#define NLA_ALIGN_LEN(len) (((len) + NLA_ALIGNTO - 1) & ~(NLA_ALIGNTO - 1))
#define NLA_DATA_PTR(attr) ((void *)((char *)(attr) + NLA_HDRLEN))
#define NLA_PAYLOAD_LEN(attr) ((int)(attr)->nla_len - NLA_HDRLEN)
#define NLA_VALID(attr, rem) \
	((rem) >= (int)sizeof(struct nlattr) && \
	 (attr)->nla_len >= sizeof(struct nlattr) && \
	 (attr)->nla_len <= (rem))
#define NLA_ADVANCE(attr, rem) \
	((rem) -= NLA_ALIGN_LEN((attr)->nla_len), \
	 (struct nlattr *)((char *)(attr) + NLA_ALIGN_LEN((attr)->nla_len)))

struct nlmsg_buffer {
	struct nlmsghdr nlh;
	struct genlmsghdr genl;
	char data[4096];
};

static unsigned int sequence;

static int add_attr(struct nlmsg_buffer *msg, size_t capacity, uint16_t type,
		    const void *data, size_t len)
{
	size_t offset = NLMSG_ALIGN(msg->nlh.nlmsg_len);
	size_t total = NLA_ALIGN_LEN(NLA_HDRLEN + len);
	struct nlattr *attr;

	if (offset + total > capacity)
		return -ENOBUFS;

	attr = (struct nlattr *)((char *)msg + offset);
	attr->nla_type = type;
	attr->nla_len = NLA_HDRLEN + len;
	if (len)
		memcpy(NLA_DATA_PTR(attr), data, len);
	memset((char *)attr + attr->nla_len, 0, total - attr->nla_len);
	msg->nlh.nlmsg_len = offset + total;
	return 0;
}

static void init_request(struct nlmsg_buffer *msg, uint16_t type,
			 uint16_t flags, uint8_t command)
{
	memset(msg, 0, sizeof(*msg));
	msg->nlh.nlmsg_len = NLMSG_LENGTH(GENL_HDRLEN);
	msg->nlh.nlmsg_type = type;
	msg->nlh.nlmsg_flags = NLM_F_REQUEST | flags;
	msg->nlh.nlmsg_seq = ++sequence;
	msg->genl.cmd = command;
	msg->genl.version = 1;
}

static int send_request(int fd, struct nlmsg_buffer *msg)
{
	struct sockaddr_nl kernel = { .nl_family = AF_NETLINK };
	ssize_t ret;

	ret = sendto(fd, msg, msg->nlh.nlmsg_len, 0,
		     (struct sockaddr *)&kernel, sizeof(kernel));
	return ret < 0 ? -errno : 0;
}

static int receive_ack(int fd, unsigned int expected_sequence)
{
	char buffer[8192];
	ssize_t len;
	struct nlmsghdr *nlh;

	for (;;) {
		len = recv(fd, buffer, sizeof(buffer), 0);
		if (len < 0)
			return -errno;

		for (nlh = (struct nlmsghdr *)buffer; NLMSG_OK(nlh, len);
		     nlh = NLMSG_NEXT(nlh, len)) {
			struct nlmsgerr *error;

			if (nlh->nlmsg_seq != expected_sequence)
				continue;
			if (nlh->nlmsg_type != NLMSG_ERROR)
				continue;

			error = NLMSG_DATA(nlh);
			return error->error;
		}
	}
}

static int resolve_family(int fd, const char *name)
{
	struct nlmsg_buffer msg;
	char buffer[8192];
	ssize_t len;
	struct nlmsghdr *nlh;
	unsigned int request_sequence;

	init_request(&msg, GENL_ID_CTRL, 0, CTRL_CMD_GETFAMILY);
	if (add_attr(&msg, sizeof(msg), CTRL_ATTR_FAMILY_NAME,
		     name, strlen(name) + 1))
		return -ENOBUFS;
	request_sequence = msg.nlh.nlmsg_seq;
	if (send_request(fd, &msg))
		return -errno;

	for (;;) {
		len = recv(fd, buffer, sizeof(buffer), 0);
		if (len < 0)
			return -errno;

		for (nlh = (struct nlmsghdr *)buffer; NLMSG_OK(nlh, len);
		     nlh = NLMSG_NEXT(nlh, len)) {
			struct genlmsghdr *genl;
			struct nlattr *attr;
			int remaining;

			if (nlh->nlmsg_seq != request_sequence)
				continue;
			if (nlh->nlmsg_type == NLMSG_ERROR) {
				struct nlmsgerr *error = NLMSG_DATA(nlh);
				return error->error ?: -ENOENT;
			}

			genl = NLMSG_DATA(nlh);
			remaining = nlh->nlmsg_len - NLMSG_LENGTH(GENL_HDRLEN);
			attr = (struct nlattr *)((char *)genl + GENL_HDRLEN);
			while (NLA_VALID(attr, remaining)) {
				if ((attr->nla_type & NLA_TYPE_MASK) ==
				    CTRL_ATTR_FAMILY_ID)
					return *(uint16_t *)NLA_DATA_PTR(attr);
				attr = NLA_ADVANCE(attr, remaining);
			}
		}
	}
}

static int set_interface_up(const char *name)
{
	struct ifreq request = {};
	int fd;

	fd = socket(AF_INET, SOCK_DGRAM, 0);
	if (fd < 0)
		return -errno;

	strncpy(request.ifr_name, name, IFNAMSIZ - 1);
	if (ioctl(fd, SIOCGIFFLAGS, &request) < 0 ||
	    (request.ifr_flags |= IFF_UP,
	     ioctl(fd, SIOCSIFFLAGS, &request) < 0)) {
		int error = -errno;
		close(fd);
		return error;
	}

	close(fd);
	return 0;
}

static int trigger_scan(int fd, int family, unsigned int ifindex)
{
	struct nlmsg_buffer msg;
	struct nlattr *nested;
	size_t nested_offset;
	unsigned int request_sequence;
	int ret;

	init_request(&msg, family, NLM_F_ACK, NL80211_CMD_TRIGGER_SCAN);
	ret = add_attr(&msg, sizeof(msg), NL80211_ATTR_IFINDEX,
		       &ifindex, sizeof(ifindex));
	if (ret)
		return ret;

	nested_offset = NLMSG_ALIGN(msg.nlh.nlmsg_len);
	ret = add_attr(&msg, sizeof(msg), NL80211_ATTR_SCAN_SSIDS | NLA_F_NESTED,
		       NULL, 0);
	if (ret)
		return ret;
	nested = (struct nlattr *)((char *)&msg + nested_offset);
	ret = add_attr(&msg, sizeof(msg), 1, NULL, 0);
	if (ret)
		return ret;
	nested->nla_len = msg.nlh.nlmsg_len - nested_offset;

	request_sequence = msg.nlh.nlmsg_seq;
	ret = send_request(fd, &msg);
	if (ret)
		return ret;
	return receive_ack(fd, request_sequence);
}

static void read_ssid(const unsigned char *ies, int length,
		      char *ssid, size_t ssid_size)
{
	while (length >= 2) {
		int id = ies[0];
		int size = ies[1];

		ies += 2;
		length -= 2;
		if (size > length)
			break;
		if (id == 0) {
			size_t copy = (size_t)size < ssid_size - 1 ?
				      (size_t)size : ssid_size - 1;
			memcpy(ssid, ies, copy);
			ssid[copy] = '\0';
			return;
		}
		ies += size;
		length -= size;
	}
	strcpy(ssid, "<hidden>");
}

static void print_bss(struct nlattr *bss)
{
	struct nlattr *attr;
	unsigned char *bssid = NULL;
	uint32_t frequency = 0;
	int32_t signal = 0;
	char ssid[33] = "<hidden>";
	int remaining = NLA_PAYLOAD_LEN(bss);

	attr = NLA_DATA_PTR(bss);
	while (NLA_VALID(attr, remaining)) {
		switch (attr->nla_type & NLA_TYPE_MASK) {
		case NL80211_BSS_BSSID:
			if (NLA_PAYLOAD_LEN(attr) == 6)
				bssid = NLA_DATA_PTR(attr);
			break;
		case NL80211_BSS_FREQUENCY:
			frequency = *(uint32_t *)NLA_DATA_PTR(attr);
			break;
		case NL80211_BSS_SIGNAL_MBM:
			signal = *(int32_t *)NLA_DATA_PTR(attr);
			break;
		case NL80211_BSS_INFORMATION_ELEMENTS:
			read_ssid(NLA_DATA_PTR(attr), NLA_PAYLOAD_LEN(attr),
				  ssid, sizeof(ssid));
			break;
		}
		attr = NLA_ADVANCE(attr, remaining);
	}

	if (bssid)
		printf("%02x:%02x:%02x:%02x:%02x:%02x %u MHz %d.%02d dBm %s\n",
		       bssid[0], bssid[1], bssid[2], bssid[3], bssid[4], bssid[5],
		       frequency, signal / 100, abs(signal % 100), ssid);
}

static int dump_scan(int fd, int family, unsigned int ifindex)
{
	struct nlmsg_buffer msg;
	char buffer[32768];
	unsigned int request_sequence;
	int found = 0;
	int ret;

	init_request(&msg, family, NLM_F_DUMP, NL80211_CMD_GET_SCAN);
	ret = add_attr(&msg, sizeof(msg), NL80211_ATTR_IFINDEX,
		       &ifindex, sizeof(ifindex));
	if (ret)
		return ret;
	request_sequence = msg.nlh.nlmsg_seq;
	ret = send_request(fd, &msg);
	if (ret)
		return ret;

	for (;;) {
		ssize_t length = recv(fd, buffer, sizeof(buffer), 0);
		struct nlmsghdr *nlh;

		if (length < 0)
			return -errno;
		for (nlh = (struct nlmsghdr *)buffer; NLMSG_OK(nlh, length);
		     nlh = NLMSG_NEXT(nlh, length)) {
			struct genlmsghdr *genl;
			struct nlattr *attr;
			int remaining;

			if (nlh->nlmsg_seq != request_sequence)
				continue;
			if (nlh->nlmsg_type == NLMSG_DONE)
				return found ? 0 : -ENODATA;
			if (nlh->nlmsg_type == NLMSG_ERROR) {
				struct nlmsgerr *error = NLMSG_DATA(nlh);
				return error->error;
			}

			genl = NLMSG_DATA(nlh);
			remaining = nlh->nlmsg_len - NLMSG_LENGTH(GENL_HDRLEN);
			attr = (struct nlattr *)((char *)genl + GENL_HDRLEN);
			while (NLA_VALID(attr, remaining)) {
				if ((attr->nla_type & NLA_TYPE_MASK) == NL80211_ATTR_BSS) {
					print_bss(attr);
					found++;
				}
				attr = NLA_ADVANCE(attr, remaining);
			}
		}
	}
}

int main(int argc, char **argv)
{
	struct sockaddr_nl local = { .nl_family = AF_NETLINK };
	const char *interface = argc > 1 ? argv[1] : "wlan0";
	unsigned int ifindex;
	int family;
	int fd;
	int ret;

	ifindex = if_nametoindex(interface);
	if (!ifindex) {
		fprintf(stderr, "%s: interface not found\n", interface);
		return 1;
	}

	ret = set_interface_up(interface);
	if (ret) {
		fprintf(stderr, "failed to bring %s up: %s\n", interface,
			strerror(-ret));
		return 1;
	}

	fd = socket(AF_NETLINK, SOCK_RAW, NETLINK_GENERIC);
	if (fd < 0 || bind(fd, (struct sockaddr *)&local, sizeof(local)) < 0) {
		perror("nl80211 socket");
		return 1;
	}

	family = resolve_family(fd, "nl80211");
	if (family < 0) {
		fprintf(stderr, "failed to resolve nl80211: %s\n", strerror(-family));
		return 1;
	}

	ret = trigger_scan(fd, family, ifindex);
	if (ret && ret != -EBUSY) {
		fprintf(stderr, "failed to trigger scan: %s\n", strerror(-ret));
		return 1;
	}

	sleep(6);
	ret = dump_scan(fd, family, ifindex);
	if (ret) {
		fprintf(stderr, "failed to read scan results: %s\n", strerror(-ret));
		return 1;
	}

	close(fd);
	return 0;
}
