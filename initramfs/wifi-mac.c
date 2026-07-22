#include <arpa/inet.h>
#include <endian.h>
#include <errno.h>
#include <linux/qrtr.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#ifndef AF_QIPCRTR
#define AF_QIPCRTR 42
#endif

#ifndef QRTR_NODE_BCAST
#define QRTR_NODE_BCAST 0xffffffffU
#endif

#ifndef QRTR_PORT_CTRL
#define QRTR_PORT_CTRL 0xfffffffeU
#endif

#define QRTR_TYPE_NEW_SERVER 4
#define QRTR_TYPE_NEW_LOOKUP 10

#define DMS_SERVICE 2
#define DMS_VERSION 1
#define DMS_GET_MAC_ADDRESS 0x005c
#define DMS_MAC_TYPE_WLAN 0

#define QMI_REQUEST 0
#define QMI_RESPONSE 2

struct qmi_header {
	uint8_t type;
	uint16_t txn_id;
	uint16_t msg_id;
	uint16_t msg_len;
} __attribute__((packed));

struct dms_get_mac_request {
	struct qmi_header header;
	uint8_t tlv_type;
	uint16_t tlv_len;
	uint32_t device;
} __attribute__((packed));

static long long monotonic_ms(void)
{
	struct timespec now;

	clock_gettime(CLOCK_MONOTONIC, &now);
	return (long long)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

static int send_lookup(int fd)
{
	struct sockaddr_qrtr local = { 0 };
	struct sockaddr_qrtr control = { 0 };
	struct qrtr_ctrl_pkt packet = {
		.cmd = htole32(QRTR_TYPE_NEW_LOOKUP),
		.server = {
			.service = htole32(DMS_SERVICE),
			.instance = htole32(DMS_VERSION),
		},
	};
	socklen_t length = sizeof(local);

	if (getsockname(fd, (struct sockaddr *)&local, &length) < 0) {
		perror("getsockname(AF_QIPCRTR)");
		return -1;
	}
	control.sq_family = AF_QIPCRTR;
	control.sq_node = local.sq_node;
	control.sq_port = QRTR_PORT_CTRL;
	if (sendto(fd, &packet, sizeof(packet), 0,
		   (struct sockaddr *)&control, sizeof(control)) != sizeof(packet)) {
		perror("QRTR DMS lookup");
		return -1;
	}
	return 0;
}

static int wait_for_dms(int fd, struct sockaddr_qrtr *server)
{
	long long deadline = monotonic_ms() + 15000;
	struct pollfd pfd = {
		.fd = fd,
		.events = POLLIN,
	};

	while (monotonic_ms() < deadline) {
		struct sockaddr_qrtr source = { 0 };
		struct qrtr_ctrl_pkt packet;
		socklen_t source_len = sizeof(source);
		int timeout = (int)(deadline - monotonic_ms());
		ssize_t length;
		uint32_t instance;

		if (poll(&pfd, 1, timeout) <= 0)
			break;
		length = recvfrom(fd, &packet, sizeof(packet), 0,
				  (struct sockaddr *)&source, &source_len);
		if (length < (ssize_t)sizeof(packet) ||
		    source.sq_port != QRTR_PORT_CTRL ||
		    le32toh(packet.cmd) != QRTR_TYPE_NEW_SERVER ||
		    le32toh(packet.server.service) != DMS_SERVICE)
			continue;
		instance = le32toh(packet.server.instance);
		if ((instance & 0xff) != DMS_VERSION || (instance >> 8) != 0)
			continue;
		server->sq_family = AF_QIPCRTR;
		server->sq_node = le32toh(packet.server.node);
		server->sq_port = le32toh(packet.server.port);
		return 0;
	}

	fprintf(stderr, "DMS QMI service did not appear\n");
	return -1;
}

static int request_wlan_mac(int fd, const struct sockaddr_qrtr *server,
			    uint8_t mac[6])
{
	struct dms_get_mac_request request = {
		.header = {
			.type = QMI_REQUEST,
			.txn_id = htole16(1),
			.msg_id = htole16(DMS_GET_MAC_ADDRESS),
			.msg_len = htole16(7),
		},
		.tlv_type = 0x01,
		.tlv_len = htole16(sizeof(request.device)),
		.device = htole32(DMS_MAC_TYPE_WLAN),
	};
	long long deadline = monotonic_ms() + 5000;
	struct pollfd pfd = {
		.fd = fd,
		.events = POLLIN,
	};
	int result = -1;
	int have_result = 0;
	int have_mac = 0;

	if (sendto(fd, &request, sizeof(request), 0,
		   (const struct sockaddr *)server, sizeof(*server)) != sizeof(request)) {
		perror("DMS Get MAC Address request");
		return -1;
	}

	while (monotonic_ms() < deadline) {
		struct sockaddr_qrtr source = { 0 };
		unsigned char response[256];
		const struct qmi_header *header;
		socklen_t source_len = sizeof(source);
		int timeout = (int)(deadline - monotonic_ms());
		size_t offset;
		size_t payload_end;
		ssize_t length;

		if (poll(&pfd, 1, timeout) <= 0)
			break;
		length = recvfrom(fd, response, sizeof(response), 0,
				  (struct sockaddr *)&source, &source_len);
		if (length < (ssize_t)sizeof(*header) ||
		    source.sq_node != server->sq_node ||
		    source.sq_port != server->sq_port)
			continue;
		header = (const struct qmi_header *)response;
		if (header->type != QMI_RESPONSE || le16toh(header->txn_id) != 1 ||
		    le16toh(header->msg_id) != DMS_GET_MAC_ADDRESS)
			continue;
		payload_end = sizeof(*header) + le16toh(header->msg_len);
		if (payload_end > (size_t)length)
			continue;

		for (offset = sizeof(*header); offset + 3 <= payload_end;) {
			uint8_t type = response[offset];
			uint16_t tlv_len;
			const unsigned char *value;

			memcpy(&tlv_len, response + offset + 1, sizeof(tlv_len));
			tlv_len = le16toh(tlv_len);
			offset += 3;
			if (offset + tlv_len > payload_end)
				break;
			value = response + offset;
			if (type == 0x02 && tlv_len == 4) {
				uint16_t qmi_result;
				uint16_t qmi_error;

				memcpy(&qmi_result, value, sizeof(qmi_result));
				memcpy(&qmi_error, value + 2, sizeof(qmi_error));
				qmi_result = le16toh(qmi_result);
				qmi_error = le16toh(qmi_error);
				have_result = 1;
				result = qmi_result == 0 ? 0 : -(int)qmi_error;
			} else if (type == 0x10 && tlv_len >= 7 && value[0] == 6) {
				for (size_t i = 0; i < 6; i++)
					mac[i] = value[6 - i];
				have_mac = 1;
			}
			offset += tlv_len;
		}
		if (have_result && result == 0 && have_mac)
			return 0;
		if (have_result && result)
			break;
	}

	if (have_result && result)
		fprintf(stderr, "DMS Get MAC Address failed: QMI error %d\n", -result);
	else
		fprintf(stderr, "DMS Get MAC Address response was incomplete\n");
	return -1;
}

int main(void)
{
	struct sockaddr_qrtr server = { 0 };
	uint8_t mac[6];
	int fd;
	int rc = 1;

	fd = socket(AF_QIPCRTR, SOCK_DGRAM | SOCK_CLOEXEC, 0);
	if (fd < 0) {
		perror("socket(AF_QIPCRTR)");
		return 1;
	}
	if (send_lookup(fd) || wait_for_dms(fd, &server) ||
	    request_wlan_mac(fd, &server, mac))
		goto out;
	if ((mac[0] & 1) || !(mac[0] | mac[1] | mac[2] | mac[3] | mac[4] | mac[5])) {
		fprintf(stderr,
			"DMS returned an invalid WLAN MAC address: %02x:%02x:%02x:%02x:%02x:%02x\n",
			mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
		goto out;
	}
	printf("%02x:%02x:%02x:%02x:%02x:%02x\n",
	       mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
	rc = 0;

out:
	close(fd);
	return rc;
}
