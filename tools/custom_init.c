/*
 * custom_init.c - minimal PID 1 for the "native boot" path.
 *
 * Boots the stock Tesla userland without dm-verity / dm-linear:
 *
 *   QEMU -kernel/-initrd
 *     -> custom_init (PID 1, inside initramfs)
 *        -> mount the edited squashfs from /dev/vda
 *        -> switch_root (MS_MOVE + chroot)
 *        -> execve /sbin/init  (runit-init)
 *           -> /etc/runit/1 -> runsvdir -> /etc/sv/*
 *
 * The stock init builds a dm-linear device out of p2/p3 + a "borrowed"
 * 1 GiB region of p4 and verifies it with an RSA-signed dm-verity
 * superblock. We skip all of that and mount the squashfs image directly,
 * which is why the rootfs may be modified freely.
 *
 * Based on the debugging write-up:
 * https://cn0xroot.wordpress.com/2026/09/20/root_tesla_os_on_qemu_part_2_debugging_fixing/
 *
 * Build: see scripts/build-initrd-custom.sh (static, no libc deps at runtime)
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <unistd.h>

#ifndef ROOT_DEVICE
#define ROOT_DEVICE "/dev/vda"
#endif

#ifndef ROOT_FSTYPE
#define ROOT_FSTYPE "squashfs"
#endif

static void die(const char *what)
{
	perror(what);
	/* Keep the console alive so the error stays readable. */
	for (;;)
		sleep(3600);
}

static void log_msg(const char *msg)
{
	ssize_t r;

	r = write(1, "custom_init: ", 13);
	r = write(1, msg, strlen(msg));
	r = write(1, "\n", 1);
	(void)r;
}

static int wait_for_device(const char *path, int timeout_s)
{
	struct stat st;
	int i;

	for (i = 0; i < timeout_s * 10; i++) {
		if (stat(path, &st) == 0)
			return 0;
		usleep(100000);
	}
	return -1;
}

int main(void)
{
	int consfd;

	/* EBUSY means a wrapper script (see build-initrd-custom.sh) already
	 * mounted it in order to load kernel modules first. */
	if (mount(NULL, "/dev", "devtmpfs", 0, NULL) < 0 && errno != EBUSY)
		die("mount /dev");

	setsid();

	consfd = open("/dev/console", O_RDWR);
	if (consfd >= 0) {
		dup2(consfd, 0);
		dup2(consfd, 1);
		dup2(consfd, 2);
		if (consfd > 2)
			close(consfd);
	}

	mount(NULL, "/proc", "proc", 0, NULL);
	mount(NULL, "/sys", "sysfs", 0, NULL);

	log_msg("waiting for " ROOT_DEVICE);
	if (wait_for_device(ROOT_DEVICE, 30) < 0)
		die("wait_for_device " ROOT_DEVICE);

	log_msg("mounting rootfs (read-only " ROOT_FSTYPE ")");
	if (mount(ROOT_DEVICE, "/mnt", ROOT_FSTYPE, MS_RDONLY, NULL) < 0) {
		if (errno == ENODEV)
			log_msg("the kernel has no " ROOT_FSTYPE " support: "
				"build the initrd with KVER/MODLOOP set");
		die("mount " ROOT_DEVICE);
	}

	/* The real init remounts these itself inside the new root. */
	umount2("/sys", MNT_DETACH);
	umount2("/proc", MNT_DETACH);
	umount2("/dev", MNT_DETACH);

	if (chdir("/mnt") < 0)
		die("chdir /mnt");
	if (mount(".", "/", NULL, MS_MOVE, NULL) < 0)
		die("MS_MOVE /");
	if (chroot(".") < 0)
		die("chroot");
	if (chdir("/") < 0)
		die("chdir /");

	log_msg("exec /sbin/init");

	{
		char *const argv[] = { "/sbin/init", NULL };
		char *const envp[] = {
			"PATH=/usr/tesla/UI/bin:/sbin:/usr/sbin:/bin:/usr/bin",
			"HOME=/root",
			"TERM=linux",
			NULL
		};

		execve("/sbin/init", argv, envp);
	}

	die("execve /sbin/init");
	return 1;
}
