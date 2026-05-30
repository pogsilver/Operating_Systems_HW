#include "os.h"


#define OFFSET 12
#define ENTRY_SIZE 9
#define MAX_LEVEL 4
#define ENTRY_BIT_MASK ((1 << ENTRY_SIZE) - 1)
/* Each frame is 2^12 Bytes, and the page table entry is 
2^3 Bytes, we'll have 2^12/2^3 = 2^9 entries for each table.*/


void page_table_update(uint64_t pt, uint64_t vpn, uint64_t ppn);
uint64_t page_table_query(uint64_t pt, uint64_t vpn);
/*Helper functions:*/
void delete_entry(uint64_t pt, uint64_t vpn);
void update_entry(uint64_t pt, uint64_t vpn, uint64_t ppn);







/**
 * @brief Queries the given pagetable for the physical\ 
 *        page number the given vpn is mapped to
 * 
 * @param pt Physical page number of the page table root
 * @param vpn The virtual page number you wish to check its mapping
 * @return uint64_t The physical page number the given vpn is mapped\
 *         to, or NO_MAPPING if there is no mapping in the page table 
 */
uint64_t page_table_query(uint64_t pt, uint64_t vpn){

    uint64_t *curr_node, entry_value, curr_entry, shift, valid_bit;
    int level;

    /* As the size of PFN is 52 bits, we need to shift it so it will be 64 bits */
    curr_node = phys_to_virt(pt << OFFSET);
    level = 0;

    while(level <= MAX_LEVEL){
        shift = (MAX_LEVEL - level) * ENTRY_SIZE;
        curr_entry = (vpn >> shift) & ENTRY_BIT_MASK;
        entry_value = curr_node[curr_entry];
        valid_bit = entry_value & 1;
        if(valid_bit != 1){
            return NO_MAPPING;
        }
        if (level < MAX_LEVEL){
            /*As we don't need the valid bit*/
            curr_node = phys_to_virt(entry_value - 1);
        }
        level++;
    }
    
    return entry_value >> OFFSET;
}

/**
 * @brief Deletes the entry of the virtual page numbber from the\
 *        page table
 * 
 * @param pt Physical page number of the page table root
 * @param vpn The virtual page number to delete from the table
 */
void delete_entry(uint64_t pt, uint64_t vpn){

    uint64_t *curr_node, curr_entry, shift;
    int level;

    curr_node = phys_to_virt(pt << OFFSET);
    level = 0;

    while(level <= MAX_LEVEL){
        shift = (MAX_LEVEL - level) * ENTRY_SIZE;
        curr_entry = (vpn >> shift) & ENTRY_BIT_MASK;
        if (level < MAX_LEVEL){
            curr_node = phys_to_virt(curr_node[curr_entry] - 1);
        }
        level++;
    }
    /*Setting the valid bit to 0 - which means invalid*/
        curr_node[curr_entry]--;
}

/**
 * @brief Maps the given virtual page number to the given physical page number\
 *        in the given page table
 * 
 * @param pt Physical page number of the page table root
 * @param vpn The virtual page number to map/rempap in the table
 * @param ppn The physical page number the vpn will be mapped to
 */
void update_entry(uint64_t pt, uint64_t vpn, uint64_t ppn){

    uint64_t *curr_node, entry_value, curr_entry, shift, valid_bit, new_page;
    int level;

    curr_node = phys_to_virt(pt << OFFSET);
    level = 0;

    while(level <= MAX_LEVEL){
        shift = (MAX_LEVEL - level) * ENTRY_SIZE;
        curr_entry = (vpn >> shift) & ENTRY_BIT_MASK;
        entry_value = curr_node[curr_entry];
        valid_bit = entry_value & 1;

        if(level < MAX_LEVEL){
            if(valid_bit != 1){
                new_page = alloc_page_frame();
                /* As the size of PFN is 52 bits, we need to shift it so it will be 64 bits with a valid\
                bit */
                curr_node[curr_entry] = (new_page << OFFSET) + 1;
                entry_value = curr_node[curr_entry];
            }
            curr_node = phys_to_virt(entry_value - 1);
        }
        level++;
    }
    /* Set the last level's entry to the given physical page number*/
    curr_node[curr_entry] = (ppn << OFFSET) + 1;

}

void page_table_update(uint64_t pt, uint64_t vpn, uint64_t ppn){

    uint64_t curr_mapping;
    curr_mapping = page_table_query(pt, vpn);
    if (curr_mapping == ppn){
        return ;
    }
    if(ppn == NO_MAPPING){
        delete_entry(pt, vpn);
        return ;
    }
    update_entry(pt, vpn, ppn);
}