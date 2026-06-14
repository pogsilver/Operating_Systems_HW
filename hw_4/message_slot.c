#define __KERNEL__
#define MODULE

#include <linux/kernel.h>    // Kernel work
#include <linux/module.h>    // Module support
#include <linux/fs.h>        // register_chrdev
#include <linux/uaccess.h>   // get_user, put_user
#include <linux/string.h>    // memset
#include <linux/slab.h>

#define MAX_MSG_LENGTH 128

MODULE_LICENSE("GPL");
MODULE_AUTHOR("YC");
MODULE_DESCRIPTION("A Message Slot implementation for HW4");
MODULE_VERSION("1.0");






// Structure to store information for each file descriptor
typedef struct {
    unsigned int channel_id; // 0 means no channel set
    int censorship_enabled; // 0 = disabled, 1 = enabled
} file_descriptor_data;


// Structure to store a message for a channel
typedef struct channel_node {
    unsigned int channel_id;
    char message[MAX_MSG_LENGTH];
    int message_length;
struct channel_node* next; // For linked list
} channel_node;


// Structure to store information for each message slot (minor number)
typedef struct slot_node {
    int minor_number;
    channel_node* channels; // Linked list of channels
    struct slot_node* next;
} slot_node;


static slot_node* slots = NULL;


/**
 * @brief Creates a node_slot object with the given minor number
 * 
 * @param minor 
 * @return slot_node* node with the given minor number. returns NULL if it failed\
 * to create one
 */
static slot_node* create_slot(int minor){

    slot_node* node;

    node = kmalloc(sizeof(slot_node), GFP_KERNEL);
    if(node == NULL){
        return NULL;
    }
    node->minor_number = minor;
    node->channels = NULL;
    node->next = NULL;
    return node;
}


/**
 * @brief a function to find the slot_node with the given minor.
 * If the given minor was valid and no slot with it was found,
 * the function creates the correct node and returns it
 * 
 * @param minor the minor number of the wanted slot
 * @return * slot_node node with the given minor number. NULL if the minor is invalid
 */
static slot_node* find_slot(int minor){
    
    slot_node* curr;
    
    curr = slots;
    if((minor < 0) || (255 < minor)){
        return NULL;
    }
    if(slots == NULL){
        slots = create_slot(minor);
        return slots;
    }
    while(curr != NULL){
        if (curr->minor_number == minor){
            return curr;
        }
        if (curr->next == NULL){
            break;
        }
        curr = curr->next;
    }
    curr->next = create_slot(minor);
    return curr->next;

}


/**
 * @brief Creates a channel_node object with the given channel number
 * 
 * @param channel_number 
 * @return channel_node* node with the given channel_number number. returns NULL if it failed\
 * to create one
 */
static channel_node* create_channel(int channel_number){

    channel_node* node;

    node = kmalloc(sizeof(channel_node), GFP_KERNEL);
    if(node == NULL){
        return NULL;
    }
    node->channel_id = channel_number;
    memset(node->message, 0, MAX_MSG_LENGTH);
    node->message_length = 0;
    node->next = NULL;
    return node;
}


/**
 * @brief a function to find the channel_node with the given channel in
 * the given slot if the channel number is valid. If it wasn't found it and the create
 * creates flag is on creates it and returns it.
 * @param slot the slot in which we search the given channel
 * @param channel the wanted channel_id
 * @param create a flag to create the channel_node if it is not found
 * @return channel_node* the channel_node in the slot with the given channel_id. NULL 
 * if the given channel is invalid 
 */
static channel_node* find_channel(slot_node* slot, int channel, int create){
    
    channel_node* curr;
    
    curr = slot->channels;
    if((channel < 0) || (1<<20 < channel)){
        return NULL;
    }
    if(curr == NULL){
        if(create){
            slot->channels = create_channel(channel);
            return slot->channels;
        }
        return NULL;
    }
    while(curr != NULL){
        if (curr->channel_id == channel){
            return curr;
        }
        if (curr->next == NULL){
            break;
        }
        curr = curr->next;
    }
    if(create){
        curr->next = create_channel(channel);
        return curr->next;
    }
    return NULL;

}

static int device_open(struct inode *inode, struct file *file){

    int minor = iminor(inode);
    file_descriptor_data* fd_data;
    slot_node* slot;

    printk(KERN_INFO "Opening device: minor = %d\n", minor);

    // Find or create message slot for this minor number
    slot = find_slot(minor);
    if(slot == NULL){
        printk(KERN_ERR "Something went wrong with the slot's minor number: minor = %d\n", minor);
        return -EINVAL;
    }
    // Allocate per-file-descriptor data
    fd_data = kmalloc(sizeof(file_descriptor_data), GFP_KERNEL);
    if (!fd_data) {
        return -ENOMEM; // Out of memory
    }

    // Initialize
    fd_data->channel_id = 0; // No channel set yet
    fd_data->censorship_enabled = 0; // Censorship disabled by default
    file->private_data = fd_data;
    return 0;
}


static int device_release(struct inode *inode, struct file *file) {
    printk(KERN_INFO "Device closed\n");

    // Free the per-file-descriptor data
    if (file->private_data){
        kfree(file->private_data);
        file->private_data = NULL;
    }
    return 0;
}

static long device_ioctl(struct file *file, unsigned int cmd, unsigned long arg){

    int minor;
    file_descriptor_data* fd_data;
    slot_node* slot;
    channel_node* channel;

    minor = iminor(file->f_inode);
    slot = find_slot(minor);
    fd_data = (file_descriptor_data*)file->private_data;

    switch(cmd){
        case MSG_SLOT_CHANNEL:

            if((arg == 0) || (1 << 20 < arg)){
                return -EINVAL;
            }
            channel = find_channel(slot, arg, 1);
            if(channel == NULL){
                return -ENOMEM;
            }
            fd_data->channel_id = channel->channel_id;
            return 0;

        case MSG_SLOT_SET_CEN:
        if (fd_data->channel_id != 0){
            fd_data->censorship_enabled = (int)arg;
            return 0;
        }
        return -EINVAL;
            
        default:
          return -EINVAL;
    }
}

static ssize_t device_write(struct file *file, const char __user *buffer, size_t length, loff_t *offset){

    int bytes_written, bytes_to_write, i, success, minor, censor;
    file_descriptor_data* fd_data;
    slot_node* slot;
    channel_node* channel;
    char tmp[MAX_MSG_LENGTH];

    memset(tmp, 0, MAX_MSG_LENGTH);

    if((0 == length) || (128 < length)){
        return -EMSGSIZE;
    }

    minor = iminor(file->f_inode);
    slot = find_slot(minor);
    fd_data = (file_descriptor_data*)file->private_data;

    if(fd_data->channel_id == 0){
        return -EINVAL;
    }
    censor = fd_data->censorship_enabled;
    channel = find_channel(slot, fd_data->channel_id, 1);

    bytes_to_write = min(length, (size_t) MAX_MSG_LENGTH);
    

    bytes_written = 0;
    
    // Copy to message into a temporary buffer:
    for(i = 0; i < bytes_to_write; i++){
        success =  get_user(tmp[i], buffer + i);
        if(success != 0){
            return -EFAULT;
        }
        if((censor) && (i % 4 == 3)){
            tmp[i] = '#';
        }
        bytes_written++;
    }

    // Copy from the buffer into the channel:
    memcpy(channel->message, tmp, bytes_to_write);
    channel->message_length = bytes_written;
    return bytes_written;
}

static ssize_t device_read(struct file *file,  char __user *buffer, size_t length, loff_t *offset){

    int i, success, minor;
    file_descriptor_data* fd_data;
    slot_node* slot;
    channel_node* channel;

    

    minor = iminor(file->f_inode);
    slot = find_slot(minor);
    fd_data = (file_descriptor_data*)file->private_data;

    if(fd_data->channel_id == 0){
        return -EINVAL;
    }
    channel = find_channel(slot, fd_data->channel_id, 0);
    if(channel == NULL){
        return -EINVAL;
    }
    if(channel->message_length == 0){
        return -EWOULDBLOCK;
    }
    if(length < channel->message_length){
        return -ENOSPC;
    }

    // Copy to message into a buffer:
    for(i = 0; i < channel->message_length; i++){
        success =  put_user(channel->message[i], buffer + i);
        if(success != 0){
            return -EFAULT;
        }
    }
    return channel->message_length;
}

static struct file_operations fops = {
.owner = THIS_MODULE,
.open = device_open,
.release = device_release,
.write = device_write,
.read = device_read,
.unlocked_ioctl = device_ioctl, // Add ioctl support
};