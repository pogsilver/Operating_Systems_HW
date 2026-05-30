/*
 * Comprehensive test harness for pt.c.
 *   gcc -Wall -O0 -g -Dmain=os_main_unused -c os.c -o os.o
 *   gcc -Wall -O0 -g -c pt.c -o pt.o
 *   gcc -Wall -O0 -g -c test.c -o test.o
 *   gcc os.o pt.o test.o -o test_hw2 && ./test_hw2
 */

#include <assert.h>
#include <stdio.h>
#include <stdint.h>
#include "os.h"

/* ---- small assertion helper that prints which test fired ------------ */
#define CHECK(cond, msg)                                                \
    do {                                                                \
        if (!(cond)) {                                                  \
            fprintf(stderr, "FAIL: %s (line %d)\n", (msg), __LINE__);   \
            return 1;                                                   \
        }                                                               \
    } while (0)

#define PASS(name) printf("  PASS: %s\n", (name))

/* Layout-dependent constants used by some white-box checks below.       */
#define BITS_PER_LEVEL 9
#define ENTRIES_PER_TABLE 512

int main(void)
{
    uint64_t pt = alloc_page_frame();

    /* ---------------------------------------------------------------- */
    printf("Group 1: empty table\n");
    /* ---------------------------------------------------------------- */
    CHECK(page_table_query(pt, 0)               == NO_MAPPING, "query 0 on empty");
    CHECK(page_table_query(pt, 1)               == NO_MAPPING, "query 1 on empty");
    CHECK(page_table_query(pt, 0xdeadbeefULL)   == NO_MAPPING, "query random on empty");
    CHECK(page_table_query(pt, (1ULL<<44)-1)    == NO_MAPPING, "query max vpn on empty");
    PASS("Group 1");

    /* ---------------------------------------------------------------- */
    printf("Group 2: basic map / query / remap\n");
    /* ---------------------------------------------------------------- */
    page_table_update(pt, 0xabcd, 0x1234);
    CHECK(page_table_query(pt, 0xabcd) == 0x1234, "basic round trip");

    page_table_update(pt, 0xabcd, 0xbeef);
    CHECK(page_table_query(pt, 0xabcd) == 0xbeef, "remap overwrites");

    page_table_update(pt, 0xabcd, 0x1234);
    CHECK(page_table_query(pt, 0xabcd) == 0x1234, "remap back");
    PASS("Group 2");

    /* ---------------------------------------------------------------- */
    printf("Group 3: siblings differing at every level\n");
    /* ---------------------------------------------------------------- */
    /* Use a fresh table so the test is self-contained.                  */
    {
        uint64_t pt3 = alloc_page_frame();
        uint64_t base = 0x12345;
        uint64_t pa   = 0x100000;

        page_table_update(pt3, base, pa);

        /* Differ only in level-4 (leaf) - bits 0..8                    */
        uint64_t v_leaf = base ^ 1ULL;
        page_table_update(pt3, v_leaf, pa + 1);

        /* Differ only in level-3 - bits 9..17                          */
        uint64_t v_l3   = base ^ (1ULL << 9);
        page_table_update(pt3, v_l3,   pa + 2);

        /* Differ only in level-2 - bits 18..26                         */
        uint64_t v_l2   = base ^ (1ULL << 18);
        page_table_update(pt3, v_l2,   pa + 3);

        /* Differ only in level-1 - bits 27..35                         */
        uint64_t v_l1   = base ^ (1ULL << 27);
        page_table_update(pt3, v_l1,   pa + 4);

        /* Differ only in level-0 (root) - bits 36..44                  */
        uint64_t v_l0   = base ^ (1ULL << 36);
        page_table_update(pt3, v_l0,   pa + 5);

        CHECK(page_table_query(pt3, base)   == pa,     "base intact");
        CHECK(page_table_query(pt3, v_leaf) == pa + 1, "leaf sibling");
        CHECK(page_table_query(pt3, v_l3)   == pa + 2, "level-3 sibling");
        CHECK(page_table_query(pt3, v_l2)   == pa + 3, "level-2 sibling");
        CHECK(page_table_query(pt3, v_l1)   == pa + 4, "level-1 sibling");
        CHECK(page_table_query(pt3, v_l0)   == pa + 5, "level-0 sibling");
    }
    PASS("Group 3");

    /* ---------------------------------------------------------------- */
    printf("Group 4: destroy semantics\n");
    /* ---------------------------------------------------------------- */
    {
        uint64_t pt4 = alloc_page_frame();

        /* Destroy of never-mapped vpn must NOT crash and NOT allocate. */
        page_table_update(pt4, 0xfeedfaceULL, NO_MAPPING);
        CHECK(page_table_query(pt4, 0xfeedfaceULL) == NO_MAPPING,
              "destroy unmapped is no-op");

        /* Map two siblings sharing all intermediates, destroy one,
           the other must remain.                                       */
        page_table_update(pt4, 0xaaa00, 0x111);
        page_table_update(pt4, 0xaaa01, 0x222);
        page_table_update(pt4, 0xaaa00, NO_MAPPING);
        CHECK(page_table_query(pt4, 0xaaa00) == NO_MAPPING, "destroyed gone");
        CHECK(page_table_query(pt4, 0xaaa01) == 0x222,      "sibling intact");

        /* Destroy the other one too; both gone.                        */
        page_table_update(pt4, 0xaaa01, NO_MAPPING);
        CHECK(page_table_query(pt4, 0xaaa01) == NO_MAPPING, "second destroyed");

        /* Destroy twice in a row is harmless.                          */
        page_table_update(pt4, 0xaaa01, NO_MAPPING);
        CHECK(page_table_query(pt4, 0xaaa01) == NO_MAPPING, "double destroy");

        /* Destroy then re-map to a different ppn.                      */
        page_table_update(pt4, 0xaaa00, 0x999);
        CHECK(page_table_query(pt4, 0xaaa00) == 0x999, "remap after destroy");
    }
    PASS("Group 4");

    /* ---------------------------------------------------------------- */
    printf("Group 5: extreme vpn / ppn values\n");
    /* ---------------------------------------------------------------- */
    {
        uint64_t pt5 = alloc_page_frame();

        /* vpn = 0 - smallest possible.                                 */
        page_table_update(pt5, 0, 0x1);
        CHECK(page_table_query(pt5, 0) == 0x1, "vpn=0");

        /* vpn = max 45-bit value (all ones in the translated range).   */
        uint64_t v_max = (1ULL << 45) - 1ULL;
        page_table_update(pt5, v_max, 0x2);
        CHECK(page_table_query(pt5, v_max) == 0x2, "vpn=2^45-1");
        CHECK(page_table_query(pt5, 0)     == 0x1, "vpn=0 still mapped");

        /* ppn = 0 must be a valid mapping (only bit 0 indicates valid). */
        page_table_update(pt5, 0xbeef, 0);
        CHECK(page_table_query(pt5, 0xbeef) == 0, "ppn=0 valid");

        /* Largest legal ppn (52-bit value, fits in PTE bits 12..63).   */
        uint64_t ppn_big = (1ULL << 52) - 1ULL;
        page_table_update(pt5, 0x1000, ppn_big);
        CHECK(page_table_query(pt5, 0x1000) == ppn_big, "max ppn");
    }
    PASS("Group 5");

    /* ---------------------------------------------------------------- */
    printf("Group 6: independence of distinct page-table roots\n");
    /* ---------------------------------------------------------------- */
    {
        uint64_t pt_a = alloc_page_frame();
        uint64_t pt_b = alloc_page_frame();
        page_table_update(pt_a, 0x42, 0xaaaa);
        page_table_update(pt_b, 0x42, 0xbbbb);
        CHECK(page_table_query(pt_a, 0x42) == 0xaaaa, "pt_a sees its mapping");
        CHECK(page_table_query(pt_b, 0x42) == 0xbbbb, "pt_b sees its mapping");

        /* Destroy in one doesn't affect the other.                     */
        page_table_update(pt_a, 0x42, NO_MAPPING);
        CHECK(page_table_query(pt_a, 0x42) == NO_MAPPING, "pt_a now empty");
        CHECK(page_table_query(pt_b, 0x42) == 0xbbbb,     "pt_b unchanged");
    }
    PASS("Group 6");

    /* ---------------------------------------------------------------- */
    printf("Group 7: bulk - many independent mappings\n");
    /* ---------------------------------------------------------------- */
    {
        uint64_t pt7 = alloc_page_frame();
        const int N = 256;
        /* Spread vpns across multiple level-4 tables and beyond by using
           a stride that touches several index bits.                    */
        uint64_t stride = 0x1101ULL; /* hits multiple index ranges      */

        for (int i = 0; i < N; i++) {
            page_table_update(pt7, i * stride, 0xc0ffee00ULL + i);
        }
        for (int i = 0; i < N; i++) {
            CHECK(page_table_query(pt7, i * stride) == 0xc0ffee00ULL + i,
                  "bulk map readback");
        }
        /* Destroy the even ones, verify odd ones survive.              */
        for (int i = 0; i < N; i += 2) {
            page_table_update(pt7, i * stride, NO_MAPPING);
        }
        for (int i = 0; i < N; i++) {
            uint64_t got = page_table_query(pt7, i * stride);
            if (i % 2 == 0) {
                CHECK(got == NO_MAPPING, "even destroyed");
            } else {
                CHECK(got == 0xc0ffee00ULL + i, "odd survived");
            }
        }
    }
    PASS("Group 7");

    /* ---------------------------------------------------------------- */
    printf("Group 8: white-box - PTE format compliance\n");
    /* ---------------------------------------------------------------- */
    {
        /* Spec: PTE bit 0 = valid, bits 1..11 must be zero,
           bits 12..63 = frame number.  We can verify by reading the
           root table directly via phys_to_virt.                        */
        uint64_t pt8 = alloc_page_frame();
        page_table_update(pt8, 0, 0xdeadbeefULL);

        uint64_t *root = (uint64_t *) phys_to_virt(pt8 << 12);
        CHECK(root != NULL, "root pointer");
        /* For vpn=0, level-0 index is 0, so root[0] is the PTE pointing
           to the level-1 table.                                        */
        uint64_t pte = root[0];
        CHECK((pte & 1ULL) == 1ULL,        "root PTE valid bit set");
        CHECK((pte & 0xFFEULL) == 0,       "root PTE bits 1..11 zero");
    }
    PASS("Group 8");

    /* ---------------------------------------------------------------- */
    printf("Group 9: query never disturbs state\n");
    /* ---------------------------------------------------------------- */
    {
        uint64_t pt9 = alloc_page_frame();
        page_table_update(pt9, 0x55, 0x77);

        /* Many queries, both hits and misses; state must be unchanged. */
        for (int i = 0; i < 1000; i++) {
            (void) page_table_query(pt9, i);
        }
        CHECK(page_table_query(pt9, 0x55) == 0x77, "still mapped");
        CHECK(page_table_query(pt9, 0x56) == NO_MAPPING, "still unmapped");
    }
    PASS("Group 9");

    printf("\nAll tests passed.\n");
    return 0;
}
