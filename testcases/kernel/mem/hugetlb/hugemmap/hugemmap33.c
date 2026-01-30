// SPDX-License-Identifier: LGPL-2.1-or-later
/*
 * Copyright (C) 2005-2007 David Gibson & Adam Litke, IBM Corporation.
 * Copyright (c) Linux Test Project, 2024
 * Copyright (C) 2025-2026 Naveed AUS, IBM Corporation.
 * Assisted by AI tools
 */

/*\
 * [Description]
 *
 * Test hugetlbfs quota accounting with filesystem size limits.
 *
 * The number of global huge pages available to a mounted hugetlbfs filesystem
 * can be limited using a quota mechanism by setting the size attribute at
 * mount time. Older kernels did not properly handle quota accounting in a
 * number of cases (e.g., for MAP_PRIVATE pages, and with MAP_SHARED reservation).
 *
 * This test replays some scenarios on a privately mounted filesystem with
 * quota to check for regressions in hugetlbfs quota accounting.
 */

#define _GNU_SOURCE
#include <sys/types.h>
#include <sys/wait.h>
#include <sys/vfs.h>
#include <sys/statfs.h>
#include <sys/mount.h>

#include "hugetlb.h"
#include "tst_safe_macros.h"

#define MNTPOINT "hugetlbfs/"

static long hpage_size;
static int private_resv;
static char quota_mnt[PATH_MAX];
static int quota_mounted;

/* map action flags */
#define ACTION_COW		0x0001
#define ACTION_TOUCH		0x0002

/* Test result expectations */
#define EXPECT_SUCCESS	0
#define EXPECT_SIGNAL	1
#define EXPECT_FAILURE	2

static void verify_quota_stat(int line, long tot, long free, long avail)
{
	struct statfs s;

	SAFE_STATFS(quota_mnt, &s);

	if ((long)s.f_blocks != tot || (long)s.f_bfree != free || (long)s.f_bavail != avail) {
		tst_res_(NULL, line, TFAIL,
			"Bad quota counters: total=%li (expected %li), "
			"free=%li (expected %li), avail=%li (expected %li)",
			(long)s.f_blocks, tot, (long)s.f_bfree, free,
			(long)s.f_bavail, avail);
	}
}

#define VERIFY_QUOTA_STAT(t, f, a) verify_quota_stat(__LINE__, t, f, a)

static void do_map(unsigned long size, int mmap_flags, int action_flags)
{
	int fd;
	char *a, *b, *c;
	char path[PATH_MAX];

	snprintf(path, sizeof(path), "%s/test_file_%d", quota_mnt, getpid());
	fd = SAFE_OPEN(path, O_CREAT | O_RDWR, 0600);
	SAFE_UNLINK(path);

	a = mmap(NULL, size, PROT_READ | PROT_WRITE, mmap_flags, fd, 0);
	if (a == MAP_FAILED) {
		tst_res(TINFO | TERRNO, "mmap failed");
		SAFE_CLOSE(fd);
		exit(1);
	}

	if (action_flags & ACTION_TOUCH) {
		for (b = a; b < a + size; b += hpage_size)
			*b = 1;
	}

	if (action_flags & ACTION_COW) {
		c = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE, fd, 0);
		if (c == MAP_FAILED) {
			tst_res(TINFO | TERRNO, "Creating COW mapping failed");
			SAFE_MUNMAP(a, size);
			SAFE_CLOSE(fd);
			exit(1);
		}
		if (*c != 1) {
			tst_res(TINFO, "Data mismatch when setting up COW");
			SAFE_MUNMAP(c, size);
			SAFE_MUNMAP(a, size);
			SAFE_CLOSE(fd);
			exit(1);
		}
		*c = 0;
		SAFE_MUNMAP(c, size);
	}

	SAFE_MUNMAP(a, size);
	SAFE_CLOSE(fd);
}

static void test_quota_scenario(int line, int expected_result,
				unsigned long size, int mmap_flags,
				int action_flags)
{
	pid_t pid;
	int status;
	int actual_result;

	pid = SAFE_FORK();
	if (pid == 0) {
		do_map(size, mmap_flags, action_flags);
		exit(0);
	}

	SAFE_WAITPID(pid, &status, 0);

	if (WIFEXITED(status)) {
		if (WEXITSTATUS(status) == 0)
			actual_result = EXPECT_SUCCESS;
		else
			actual_result = EXPECT_FAILURE;
	} else {
		actual_result = EXPECT_SIGNAL;
	}

	if (actual_result != expected_result) {
		const char *result_names[] = {"success", "signal", "failure"};
		tst_res_(NULL, line, TFAIL,
			"Unexpected result: expected %s, got %s",
			result_names[expected_result],
			result_names[actual_result]);
	}
}

#define TEST_QUOTA(exp, size, flags, actions) \
	test_quota_scenario(__LINE__, exp, size, flags, actions)

static int kernel_has_private_reservations(void)
{
	int fd;
	long t, f, r, s;
	long nt, nf, nr, ns;
	void *p;
	char path[PATH_MAX];

	t = SAFE_READ_MEMINFO(MEMINFO_HPAGE_TOTAL);
	f = SAFE_READ_MEMINFO(MEMINFO_HPAGE_FREE);
	r = SAFE_READ_MEMINFO(MEMINFO_HPAGE_RSVD);
	s = SAFE_READ_MEMINFO(MEMINFO_HPAGE_SURP);

	snprintf(path, sizeof(path), "%s/test_priv_resv", MNTPOINT);
	fd = SAFE_OPEN(path, O_CREAT | O_RDWR, 0600);
	SAFE_UNLINK(path);

	p = SAFE_MMAP(NULL, hpage_size, PROT_READ | PROT_WRITE,
		      MAP_PRIVATE, fd, 0);

	nt = SAFE_READ_MEMINFO(MEMINFO_HPAGE_TOTAL);
	nf = SAFE_READ_MEMINFO(MEMINFO_HPAGE_FREE);
	nr = SAFE_READ_MEMINFO(MEMINFO_HPAGE_RSVD);
	ns = SAFE_READ_MEMINFO(MEMINFO_HPAGE_SURP);

	SAFE_MUNMAP(p, hpage_size);
	SAFE_CLOSE(fd);

	/* Check if reservation was created for private mapping */
	if ((nt == t + 1) && (nf == f + 1) && (ns == s + 1) && (nr == r + 1))
		return 1;
	else if ((nt == t) && (nf == f) && (ns == s)) {
		if (nr == r + 1)
			return 1;
		else if (nr == r)
			return 0;
	}

	tst_brk(TCONF, "Unexpected counter state - "
		"T:%li F:%li R:%li S:%li -> T:%li F:%li R:%li S:%li",
		t, f, r, s, nt, nf, nr, ns);
	return -1;
}

static void run_test(void)
{
	int bad_priv_resv;

	tst_res(TINFO, "Testing hugetlbfs quota accounting");

	bad_priv_resv = private_resv ? EXPECT_FAILURE : EXPECT_SIGNAL;

	/*
	 * Check that unused quota is cleared when untouched mmaps are
	 * cleaned up.
	 */
	tst_res(TINFO, "Test: Unused quota cleanup for untouched mappings");
	TEST_QUOTA(EXPECT_SUCCESS, hpage_size, MAP_PRIVATE, 0);
	VERIFY_QUOTA_STAT(1, 1, 1);
	TEST_QUOTA(EXPECT_SUCCESS, hpage_size, MAP_SHARED, 0);
	VERIFY_QUOTA_STAT(1, 1, 1);

	/*
	 * Check that simple page instantiation works within quota limits
	 * for private and shared mappings.
	 */
	tst_res(TINFO, "Test: Page instantiation within quota limits");
	TEST_QUOTA(EXPECT_SUCCESS, hpage_size, MAP_PRIVATE, ACTION_TOUCH);
	TEST_QUOTA(EXPECT_SUCCESS, hpage_size, MAP_SHARED, ACTION_TOUCH);

	/*
	 * Page instantiation should be refused if doing so puts the fs
	 * over quota.
	 */
	tst_res(TINFO, "Test: Page instantiation over quota should fail");
	TEST_QUOTA(EXPECT_FAILURE, 2 * hpage_size, MAP_SHARED, ACTION_TOUCH);

	/*
	 * If private mappings are reserved, the quota is checked up front
	 * (as is the case for shared mappings).
	 */
	tst_res(TINFO, "Test: Private mapping quota check");
	TEST_QUOTA(bad_priv_resv, 2 * hpage_size, MAP_PRIVATE, ACTION_TOUCH);

	/*
	 * COW should not be allowed if doing so puts the fs over quota.
	 */
	tst_res(TINFO, "Test: COW over quota should fail");
	TEST_QUOTA(bad_priv_resv, hpage_size, MAP_SHARED,
		   ACTION_TOUCH | ACTION_COW);
	TEST_QUOTA(bad_priv_resv, hpage_size, MAP_PRIVATE,
		   ACTION_TOUCH | ACTION_COW);

	/*
	 * Make sure that operations within the quota will succeed after
	 * some failures.
	 */
	tst_res(TINFO, "Test: Operations within quota after failures");
	TEST_QUOTA(EXPECT_SUCCESS, hpage_size, MAP_SHARED, ACTION_TOUCH);
	TEST_QUOTA(EXPECT_SUCCESS, hpage_size, MAP_PRIVATE, ACTION_TOUCH);

	tst_res(TPASS, "Hugetlbfs quota accounting works correctly");
}

static void setup(void)
{
	char mount_opts[BUFSIZ];

	hpage_size = tst_get_hugepage_size();

	/* Create a quota-limited hugetlbfs mount */
	snprintf(quota_mnt, sizeof(quota_mnt), "%s/quota_test", MNTPOINT);
	SAFE_MKDIR(quota_mnt, 0755);

	snprintf(mount_opts, sizeof(mount_opts), "size=%luK",
		 hpage_size / 1024);

	if (mount("none", quota_mnt, "hugetlbfs", 0, mount_opts) == -1) {
		if (errno == ENOSYS || errno == ENODEV)
			tst_brk(TCONF, "hugetlbfs not supported");
		tst_brk(TBROK | TERRNO, "mount() failed");
	}
	quota_mounted = 1;

	tst_res(TINFO, "Mounted hugetlbfs with quota at %s (size=%luK)",
		quota_mnt, hpage_size / 1024);

	private_resv = kernel_has_private_reservations();
	tst_res(TINFO, "Kernel %s private reservations",
		private_resv ? "has" : "does not have");
}

static void cleanup(void)
{
	if (quota_mounted) {
		SAFE_UMOUNT(quota_mnt);
		SAFE_RMDIR(quota_mnt);
	}
}

static struct tst_test test = {
	.needs_root = 1,
	.mntpoint = MNTPOINT,
	.needs_hugetlbfs = 1,
	.needs_tmpdir = 1,
	.forks_child = 1,
	.setup = setup,
	.cleanup = cleanup,
	.test_all = run_test,
	.hugepages = {2, TST_NEEDS},
};

