#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#define PCC_OFFSET 32
#define LISTEN_QUEUE_SIZE 10


void print_pcc_total(uint32_t pcc[]){
    int i, c;
    
    for(i = 0; i < 95; i++){
        c = i + PCC_OFFSET;
        if (pcc[i] > 0){
        printf("char '%c' : %u times\n", (char)c, pcc[c]);
        }
    }
}





uint32_t pcc_total[95] = {0};
// memset(pcc_total, 0, sizeof(pcc_total));


int main(int argc, char *argv[]){

    int listenfd, er, option_value, connfd;
    uint16_t port;
    struct sockaddr_in serv_addr, peer_addr;
    socklen_t addrsize;

    // Input validity check
    if (argc != 2){
        fprintf(stderr, "Invalid arguments\n");
        exit(1);
    }

    // Setting up the connection
    port = atoi(argv[1]);

    listenfd = socket(AF_INET, SOCK_STREAM, 0);
    if(listenfd < 0){
        perror("Failed to initiate socket");
        exit(1);
    }
    option_value = 1;
    // Disabling the TIME_WAIT 
    er = setsockopt(listenfd, SOL_SOCKET, SO_REUSEADDR, &option_value, sizeof(option_value));
    if(er < 0){
        perror("Failed to disable TIME_WAIT");
        exit(1);
    }

    serv_addr.sin_family = AF_INET;
    serv_addr.sin_addr.s_addr = htonl(INADDR_ANY);
    serv_addr.sin_port = htons(port);
    addrsize = sizeof(struct sockaddr_in);

    er = bind(listenfd, (struct sockaddr *)&serv_addr, addrsize);
    if(er < 0){
        perror("Failed to bind socket");
        exit(1);
    }

    // Waiting for connection and connecting
    er = listen(listenfd, LISTEN_QUEUE_SIZE);
    if(er < 0){
        perror("Failed to initiate listening state");
        exit(1);
    }

    while(1){
        connfd = accept(listenfd, (struct sockaddr *)&peer_addr, &addrsize);

        if(connfd < 0){
            perror("Failed to accept connection");
        exit(1);
        }

        er = close(connfd);
        if(er < 0){
            perror("Failed to close socket");
            exit(1);
        }
    }
    }

