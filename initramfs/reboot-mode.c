#include <errno.h>
#include <linux/reboot.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

int main(int argc, char **argv)
{
	if (argc != 2 || (strcmp(argv[1], "bootloader") && strcmp(argv[1], "recovery"))) {
		fprintf(stderr, "usage: %s bootloader|recovery\n", argv[0]);
		return 2;
	}

	sync();
	if (syscall(SYS_reboot, LINUX_REBOOT_MAGIC1, LINUX_REBOOT_MAGIC2,
		    LINUX_REBOOT_CMD_RESTART2, argv[1]) < 0) {
		fprintf(stderr, "reboot: %s\n", strerror(errno));
		return 1;
	}

	return 0;
}
