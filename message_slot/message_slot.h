#ifndef MESSAGE_SLOT_H
#define MESSAGE_SLOT_H
#include <linux/ioctl.h>
// The major device number
#define MAJOR_NUM 235
#define MAX_MSG_LENGTH 128
// Set the message of the device driver
#define MSG_SLOT_CHANNEL _IOW(MAJOR_NUM, 0, unsigned int)
#define MSG_SLOT_SET_CEN _IOW(MAJOR_NUM, 1, unsigned int)
#endif