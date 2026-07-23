// SPDX-License-Identifier: GPL-2.0-only

#include <bluetooth/bluetooth.h>
#include <bluetooth/hci.h>

#include <errno.h>
#include <poll.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <unistd.h>

#define MGMT_INDEX_NONE 0xffff
#define MGMT_OP_SET_POWERED 0x0005
#define MGMT_OP_SET_LE 0x000d
#define MGMT_OP_START_DISCOVERY 0x0023
#define MGMT_OP_STOP_DISCOVERY 0x0024
#define MGMT_OP_SET_PUBLIC_ADDRESS 0x0039
#define MGMT_EV_CMD_COMPLETE 0x0001
#define MGMT_EV_CMD_STATUS 0x0002
#define MGMT_EV_DEVICE_FOUND 0x0012

struct mgmt_hdr {
	uint16_t opcode;
	uint16_t index;
	uint16_t len;
} __attribute__((packed));

struct mgmt_discovery {
	struct mgmt_hdr hdr;
	uint8_t type;
} __attribute__((packed));

static void print_bdaddr(const bdaddr_t *addr)
{
	for (int i = 5; i >= 0; i--)
		printf("%02X%c", addr->b[i], i ? ':' : '\n');
}

static int read_persist_address(const char *path, bdaddr_t *addr)
{
	unsigned char record[9];
	FILE *file;

	file = fopen(path, "rb");
	if (!file) {
		perror(path);
		return -1;
	}
	if (fread(record, 1, sizeof(record), file) != sizeof(record)) {
		fprintf(stderr, "%s: invalid Bluetooth NV record length\n", path);
		fclose(file);
		return -1;
	}
	fclose(file);
	if (record[0] != 0x01 || record[1] != 0x00 || record[2] != 0x06) {
		fprintf(stderr, "%s: invalid Bluetooth NV record header\n", path);
		return -1;
	}
	memcpy(addr->b, record + 3, sizeof(addr->b));
	return 0;
}

static int send_mgmt_command(int dev_id, uint16_t command_opcode,
			     const void *payload, uint16_t payload_len)
{
	struct sockaddr_hci sa = {
		.hci_family = AF_BLUETOOTH,
		.hci_dev = MGMT_INDEX_NONE,
		.hci_channel = HCI_CHANNEL_CONTROL,
	};
	unsigned char command[sizeof(struct mgmt_hdr) + sizeof(bdaddr_t)] = { 0 };
	struct mgmt_hdr *command_hdr = (struct mgmt_hdr *)command;
	unsigned char response[512];
	struct pollfd pfd = { 0 };
	int fd = -1;
	ssize_t sent = -1;

	if (payload_len > sizeof(bdaddr_t)) {
		return -1;
	}
	command_hdr->opcode = command_opcode;
	command_hdr->index = (uint16_t)dev_id;
	command_hdr->len = payload_len;
	memcpy(command + sizeof(*command_hdr), payload, payload_len);
	for (int retry = 0; retry < 50; retry++) {
		fd = socket(AF_BLUETOOTH, SOCK_RAW | SOCK_CLOEXEC, BTPROTO_HCI);
		if (fd >= 0 && !bind(fd, (struct sockaddr *)&sa, sizeof(sa))) {
			sent = send(fd, command, sizeof(*command_hdr) + payload_len, 0);
			if (sent == (ssize_t)(sizeof(*command_hdr) + payload_len))
				break;
		}
		if (fd >= 0)
			close(fd);
		fd = -1;
		usleep(100000);
	}
	if (fd < 0) {
		fprintf(stderr,
			"management command 0x%04x send failed: sent=%zd errno=%d (%s)\n",
			command_opcode, sent, errno, strerror(errno));
		return -1;
	}
	if (sent != (ssize_t)(sizeof(*command_hdr) + payload_len)) {
		fprintf(stderr, "management command 0x%04x short send: %zd\n",
			command_opcode, sent);
		close(fd);
		return -1;
	}

	pfd.fd = fd;
	pfd.events = POLLIN;
	for (;;) {
		struct mgmt_hdr *hdr;
		uint16_t event;
		uint16_t index;
		uint16_t opcode;
		ssize_t length;

		if (poll(&pfd, 1, 5000) <= 0) {
			fprintf(stderr, "management command 0x%04x timed out\n",
				command_opcode);
			close(fd);
			return -1;
		}
		length = recv(fd, response, sizeof(response), 0);
		if (length < (ssize_t)(sizeof(*hdr) + 3))
			continue;
		hdr = (struct mgmt_hdr *)response;
		event = hdr->opcode;
		index = hdr->index;
		if (index != (uint16_t)dev_id ||
		    (event != MGMT_EV_CMD_COMPLETE && event != MGMT_EV_CMD_STATUS))
			continue;
		opcode = response[sizeof(*hdr)] |
			 (response[sizeof(*hdr) + 1] << 8);
		if (opcode != command_opcode)
			continue;
		if (response[sizeof(*hdr) + 2]) {
			fprintf(stderr, "management command 0x%04x status=0x%02x\n",
				command_opcode,
				response[sizeof(*hdr) + 2]);
			close(fd);
			return -1;
		}
		break;
	}

	close(fd);
	return 0;
}

static int set_public_address(int dev_id, const bdaddr_t *addr)
{
	return send_mgmt_command(dev_id, MGMT_OP_SET_PUBLIC_ADDRESS,
				 addr, sizeof(*addr));
}

static int set_powered(int dev_id, int powered)
{
	unsigned char value = powered ? 1 : 0;

	return send_mgmt_command(dev_id, MGMT_OP_SET_POWERED, &value, sizeof(value));
}

static int set_le(int dev_id, int enabled)
{
	unsigned char value = enabled ? 1 : 0;

	return send_mgmt_command(dev_id, MGMT_OP_SET_LE, &value, sizeof(value));
}

static long long monotonic_ms(void)
{
	struct timespec now;

	clock_gettime(CLOCK_MONOTONIC, &now);
	return (long long)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

static void print_eir_name(const unsigned char *eir, size_t length)
{
	size_t offset = 0;

	while (offset < length) {
		size_t field_len = eir[offset];
		unsigned char type;

		if (!field_len || field_len + offset >= length)
			break;
		type = eir[offset + 1];
		if (type == 0x08 || type == 0x09) {
			printf(" name=");
			for (size_t i = 0; i + 1 < field_len; i++) {
				unsigned char c = eir[offset + 2 + i];
				putchar(c >= 0x20 && c <= 0x7e ? c : '.');
			}
			return;
		}
		offset += field_len + 1;
	}
}

static int run_discovery(int dev_id)
{
	struct sockaddr_hci sa = {
		.hci_family = AF_BLUETOOTH,
		.hci_dev = MGMT_INDEX_NONE,
		.hci_channel = HCI_CHANNEL_CONTROL,
	};
	struct mgmt_discovery cmd = {
		.hdr = {
			.opcode = MGMT_OP_START_DISCOVERY,
			.index = (uint16_t)dev_id,
			.len = 1,
		},
		.type = 0x06,
	};
	unsigned char response[2048];
	long long deadline = monotonic_ms() + 12000;
	struct pollfd pfd = { 0 };
	int started = 0;
	int found = 0;
	int fd;

	fd = socket(AF_BLUETOOTH, SOCK_RAW | SOCK_CLOEXEC, BTPROTO_HCI);
	if (fd < 0 || bind(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
		perror("discovery management socket");
		if (fd >= 0)
			close(fd);
		return -1;
	}
	if (send(fd, &cmd, sizeof(cmd), 0) != sizeof(cmd)) {
		perror("MGMT_OP_START_DISCOVERY send");
		close(fd);
		return -1;
	}

	pfd.fd = fd;
	pfd.events = POLLIN;
	while (monotonic_ms() < deadline) {
		struct mgmt_hdr *hdr;
		unsigned char *data;
		uint16_t data_len;
		ssize_t length;

		if (poll(&pfd, 1, 500) <= 0)
			continue;
		length = recv(fd, response, sizeof(response), 0);
		if (length < (ssize_t)sizeof(*hdr))
			continue;
		hdr = (struct mgmt_hdr *)response;
		data = response + sizeof(*hdr);
		data_len = hdr->len;
		if (hdr->index == (uint16_t)dev_id && data_len >= 3 &&
		    (hdr->opcode == MGMT_EV_CMD_COMPLETE ||
		     hdr->opcode == MGMT_EV_CMD_STATUS) &&
		    (uint16_t)(data[0] | (data[1] << 8)) ==
		    MGMT_OP_START_DISCOVERY) {
			if (data[2]) {
				fprintf(stderr, "MGMT_OP_START_DISCOVERY status=0x%02x\n",
					data[2]);
				close(fd);
				return -1;
			}
			started = 1;
			continue;
		}
		if (hdr->opcode != MGMT_EV_DEVICE_FOUND ||
		    hdr->index != (uint16_t)dev_id || data_len < 14 ||
		    length < (ssize_t)(sizeof(*hdr) + data_len))
			continue;
		printf("discovered[%d]=", found);
		for (int i = 5; i >= 0; i--)
			printf("%02X%c", data[i], i ? ':' : ' ');
		printf(" address_type=%u rssi=%d", data[6], (int8_t)data[7]);
		if ((uint16_t)(data[12] | (data[13] << 8)) <= data_len - 14)
			print_eir_name(data + 14, data[12] | (data[13] << 8));
		putchar('\n');
		found++;
	}

	cmd.hdr.opcode = MGMT_OP_STOP_DISCOVERY;
	(void)send(fd, &cmd, sizeof(cmd), 0);
	close(fd);
	if (!started) {
		fprintf(stderr, "MGMT_OP_START_DISCOVERY had no response\n");
		return -1;
	}
	printf("mgmt_discovery_results=%d\n", found);
	return found;
}

int main(int argc, char **argv)
{
	struct hci_dev_list_req *dl;
	struct hci_inquiry_req *ir;
	struct hci_dev_info di = { 0 };
	inquiry_info *ii;
	size_t dl_size = sizeof(*dl) + HCI_MAX_DEV * sizeof(dl->dev_req[0]);
	size_t ir_size = sizeof(*ir) + 32 * sizeof(*ii);
	int dev_id;
	int fd;
	int rc;
	bdaddr_t persist_addr;
	const char *persist_path = NULL;
	bool configure_only = false;

	if (argc == 3 && !strcmp(argv[1], "--configure-only")) {
		configure_only = true;
		persist_path = argv[2];
	} else if (argc == 2) {
		persist_path = argv[1];
	} else if (argc != 1) {
		fprintf(stderr, "usage: %s [--configure-only] [persist-bt-nv]\n",
			argv[0]);
		return 2;
	}

	fd = socket(AF_BLUETOOTH, SOCK_RAW | SOCK_CLOEXEC, BTPROTO_HCI);
	if (fd < 0) {
		perror("socket(AF_BLUETOOTH)");
		return 1;
	}

	dl = calloc(1, dl_size);
	if (!dl) {
		perror("calloc(device list)");
		close(fd);
		return 1;
	}
	dl->dev_num = HCI_MAX_DEV;
	if (ioctl(fd, HCIGETDEVLIST, dl) < 0) {
		perror("HCIGETDEVLIST");
		free(dl);
		close(fd);
		return 1;
	}
	if (!dl->dev_num) {
		fprintf(stderr, "No HCI controller registered\n");
		free(dl);
		close(fd);
		return 1;
	}

	dev_id = dl->dev_req[0].dev_id;
	free(dl);
	if (persist_path) {
		if (ioctl(fd, HCIDEVDOWN, dev_id) < 0 && errno != EALREADY &&
		    errno != ENODEV) {
			perror("HCIDEVDOWN");
			close(fd);
			return 1;
		}
		if (read_persist_address(persist_path, &persist_addr) < 0 ||
		    set_public_address(dev_id, &persist_addr) < 0) {
			close(fd);
			return 1;
		}
	}
	if (set_powered(dev_id, 1) < 0) {
		close(fd);
		return 1;
	}
	if (set_le(dev_id, 1) < 0) {
		close(fd);
		return 1;
	}
	for (int retry = 0; retry < 80; retry++) {
		memset(&di, 0, sizeof(di));
		di.dev_id = dev_id;
		if (!ioctl(fd, HCIGETDEVINFO, &di) &&
		    (di.flags & (1U << HCI_UP)) &&
		    (!persist_path ||
		     !memcmp(di.bdaddr.b, persist_addr.b, sizeof(di.bdaddr.b))))
			break;
		usleep(100000);
	}
	if (!(di.flags & (1U << HCI_UP)) ||
	    (persist_path && memcmp(di.bdaddr.b, persist_addr.b,
				    sizeof(di.bdaddr.b)))) {
		fprintf(stderr, "Controller did not power up with the persist address\n");
		close(fd);
		return 1;
	}
	if (persist_path) {
		printf("configured_address=");
		print_bdaddr(&persist_addr);
	}
	di.dev_id = dev_id;
	if (ioctl(fd, HCIGETDEVINFO, &di) < 0) {
		perror("HCIGETDEVINFO");
		close(fd);
		return 1;
	}

	printf("controller=%s id=%d address=", di.name, dev_id);
	print_bdaddr(&di.bdaddr);
	printf("flags=0x%08x type=%u acl_mtu=%u acl_pkts=%u\n",
	       di.flags, di.type, di.acl_mtu, di.acl_pkts);
	if (configure_only) {
		close(fd);
		return 0;
	}

	ir = calloc(1, ir_size);
	if (!ir) {
		perror("calloc(inquiry)");
		close(fd);
		return 1;
	}
	ir->dev_id = dev_id;
	ir->flags = IREQ_CACHE_FLUSH;
	ir->lap[0] = 0x33;
	ir->lap[1] = 0x8b;
	ir->lap[2] = 0x9e;
	ir->length = 8;
	ir->num_rsp = 32;

	rc = ioctl(fd, HCIINQUIRY, ir);
	if (rc < 0) {
		perror("HCIINQUIRY");
		free(ir);
		close(fd);
		return 1;
	}

	printf("inquiry_results=%d\n", rc);
	ii = (inquiry_info *)(ir + 1);
	for (int i = 0; i < rc; i++) {
		printf("device[%d]=", i);
		print_bdaddr(&ii[i].bdaddr);
	}
	if (run_discovery(dev_id) < 0) {
		free(ir);
		close(fd);
		return 1;
	}

	free(ir);
	close(fd);
	return 0;
}
