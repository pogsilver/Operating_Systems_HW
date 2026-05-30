
#define _GNU_SOURCE

#include <assert.h>
#include <stdlib.h>
#include <stdio.h>
#include <err.h>
#include <sys/mman.h>

#include "os.h"

/* 2^20 pages ought to be enough for anybody */
#define NPAGES	(1024*1024)

static char* pages[NPAGES];

uint64_t alloc_page_frame(void)
{
	static uint64_t nalloc;
	uint64_t ppn;
	void* va;

	if (nalloc == NPAGES)
		errx(1, "out of physical memory");

	/* OS memory management isn't really this simple */
	ppn = nalloc;
	nalloc++;

	va = mmap(NULL, 4096, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
	if (va == MAP_FAILED)
		err(1, "mmap failed");

	pages[ppn] = va;
	return ppn + 0xbaaaaaad;
}

void* phys_to_virt(uint64_t phys_addr)
{
	uint64_t ppn = (phys_addr >> 12) - 0xbaaaaaad;
	uint64_t off = phys_addr & 0xfff;
	char* va = NULL;

	if (ppn < NPAGES)
		va = pages[ppn] + off;

	return va;
}

int main(int argc, char **argv)
{
	uint64_t pt = alloc_page_frame();

	assert(page_table_query(pt, 0xcafecafeeee) == NO_MAPPING);
	assert(page_table_query(pt, 0xfffecafeeee) == NO_MAPPING);
	assert(page_table_query(pt, 0xcafecafeeff) == NO_MAPPING);
	page_table_update(pt, 0xcafecafeeee, 0xf00d);
	assert(page_table_query(pt, 0xcafecafeeee) == 0xf00d);
	assert(page_table_query(pt, 0xfffecafeeee) == NO_MAPPING);
	assert(page_table_query(pt, 0xcafecafeeff) == NO_MAPPING);
	page_table_update(pt, 0xcafecafeeee, NO_MAPPING);
	assert(page_table_query(pt, 0xcafecafeeee) == NO_MAPPING);
	assert(page_table_query(pt, 0xfffecafeeee) == NO_MAPPING);
	assert(page_table_query(pt, 0xcafecafeeff) == NO_MAPPING);

	return 0;
}

