#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include "message_slot.h"


int main(int argc, char* argv[]){


    char *slot_path;
    int channel, fd, bytes_read;
    char buf[MAX_MSG_LENGTH];

    if(argc != 3){
        perror("Invalid number of arguments");
        exit(1);
    }
    slot_path = argv[1];
    channel = atoi(argv[2]);
    if(channel == 0){
        perror("No such channel");
        exit(1);
    }

    fd = open(slot_path, O_RDONLY);
    if(fd < 0){
        perror("Failed to open the message slot");
        exit(1);
    }

    if(ioctl(fd, MSG_SLOT_CHANNEL, channel) < 0){
        perror("Failed to set message_slot channel");
        exit(1);
    }

    bytes_read = read(fd, buf, MAX_MSG_LENGTH);

    if( bytes_read < 0){
        perror("Failed to read message from the message_slot");
        exit(1);
    }
    if(write(1, buf, bytes_read) < 0){
        perror("Failed to write message to stdout");
        exit(1);
    }
    if(close(fd) < 0){
        perror("Failed to close the message slot");
        exit(1);
    }
    exit(0);


}
