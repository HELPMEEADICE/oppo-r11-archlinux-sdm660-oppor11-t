// SPDX-License-Identifier: MIT
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define DRM_IOCTL_BASE 'd'
#define DRM_IOWR(nr, type) _IOWR(DRM_IOCTL_BASE, nr, type)
#define DRM_COMMAND_BASE 0x40
#define DRM_IOCTL_VERSION DRM_IOWR(0x00, struct drm_version)
#define DRM_MSM_GET_PARAM 0x00
#define DRM_IOCTL_MSM_GET_PARAM \
	DRM_IOWR(DRM_COMMAND_BASE + DRM_MSM_GET_PARAM, struct drm_msm_param)

#define MSM_PIPE_3D0 0x10
#define MSM_PARAM_GPU_ID 0x01
#define MSM_PARAM_CHIP_ID 0x03
#define MSM_PARAM_FAULTS 0x09

struct drm_version {
	int version_major;
	int version_minor;
	int version_patchlevel;
	size_t name_len;
	char *name;
	size_t date_len;
	char *date;
	size_t desc_len;
	char *desc;
};

struct drm_msm_param {
	uint32_t pipe;
	uint32_t param;
	uint64_t value;
	uint32_t len;
	uint32_t pad;
};

static uint64_t get_param(int fd, uint32_t param)
{
	struct drm_msm_param req = {
		.pipe = MSM_PIPE_3D0,
		.param = param,
	};

	if (ioctl(fd, DRM_IOCTL_MSM_GET_PARAM, &req) < 0) {
		fprintf(stderr, "GET_PARAM %#x failed: %s\n", param,
			strerror(errno));
		exit(1);
	}
	return req.value;
}

int main(void)
{
	char name[32] = { 0 };
	char date[32] = { 0 };
	char desc[128] = { 0 };
	struct drm_version ver = {
		.name_len = sizeof(name),
		.name = name,
		.date_len = sizeof(date),
		.date = date,
		.desc_len = sizeof(desc),
		.desc = desc,
	};
	uint64_t gpu_id, chip_id, faults;
	int fd = open("/dev/dri/renderD128", O_RDWR | O_CLOEXEC);

	if (fd < 0) {
		fprintf(stderr, "open renderD128: %s\n", strerror(errno));
		return 1;
	}
	if (ioctl(fd, DRM_IOCTL_VERSION, &ver) < 0) {
		fprintf(stderr, "DRM_IOCTL_VERSION: %s\n", strerror(errno));
		return 1;
	}
	printf("DRM driver: %s %d.%d.%d\n", name, ver.version_major,
	       ver.version_minor, ver.version_patchlevel);
	if (strcmp(name, "msm") != 0) {
		fprintf(stderr, "not msm driver\n");
		return 1;
	}

	gpu_id = get_param(fd, MSM_PARAM_GPU_ID);
	chip_id = get_param(fd, MSM_PARAM_CHIP_ID);
	faults = get_param(fd, MSM_PARAM_FAULTS);
	printf("GPU_ID: %llu\nCHIP_ID: %#llx\nFAULTS: %llu\n",
	       (unsigned long long)gpu_id, (unsigned long long)chip_id,
	       (unsigned long long)faults);

	if (gpu_id != 512 || chip_id != 0x05010200) {
		fprintf(stderr, "unexpected Adreno identity\n");
		return 1;
	}
	if (faults != 0) {
		fprintf(stderr, "non-zero GPU fault count\n");
		return 1;
	}
	printf("PASS: Adreno 512 MSM GPU probe\n");
	return 0;
}
