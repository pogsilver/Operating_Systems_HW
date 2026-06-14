#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include "message_slot.h"


int main(int argc, char* argv[]){

    int channel_id, censorship, fd;
    char *slot_path, *message;
   
    if(argc != 5){
        perror("Invalid number of arguments");
        exit(1);
    }
    slot_path = argv[1];
    channel_id = atoi(argv[2]);
    if(channel_id == 0){
        perror("No such channel");
        exit(1);
    }
    censorship = atoi(argv[3]);
    message = argv[4];

    //Open the message slot
    fd = open(slot_path, O_RDWR);
    if(fd < 0){
        perror("Failed to open the message slot");
        exit(1);
    }
    
    if(ioctl(fd, MSG_SLOT_SET_CEN, censorship) < 0){
        perror("Failed to set message_slot channel censorship");
        exit(1);
    }
    if(ioctl(fd, MSG_SLOT_CHANNEL, channel_id) < 0){
        perror("Failed to set message_slot channel");
        exit(1);
    }

    if(write(fd, message, strlen(message)) < 0){
        perror("Failed to write message to the message_slot");
        exit(1);
    }

    if(close(fd) < 0){
        perror("Failed to close the message slot");
        exit(1);
    }
    exit(0);

}