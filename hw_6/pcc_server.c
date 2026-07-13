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

#define MIN(a, b) (((a) < (b)) ? (a) : (b))

#define PCC_OFFSET 32
#define NUM_OF_PCC 95
#define LISTEN_QUEUE_SIZE 10
#define MAX_BUFF_SIZE 1000000
#define N 4

uint32_t pcc_total[NUM_OF_PCC] = {0};


/**
 * @brief Prints the given array values in the given format:
 * "char '%c' : %u times\n", (char)c, pcc[i], where is a counter
 * to the amount of appearances of c
 * 
 * @param pcc an array that counts appearances of printable characters
 */
void print_pcc_total(uint32_t pcc[]){
    int i, c;
    
    for(i = 0; i < NUM_OF_PCC; i++){
        c = i + PCC_OFFSET;
        if (pcc[i] > 0){
        printf("char '%c' : %u times\n", (char)c, pcc[i]);
        }
    }
}


/**
 * @brief Reads the the given k amount of bytes to the given buffer from
 * the given socket. 
 * Returns:
 *  k on success
 *  0 in case the connection was closed
 *  -1 if an error occurred
 * 
 * @param sockfd the fd of the socket
 * @param buf the buffer to read to
 * @param k amount of bytes to be read
 * @return ssize_t The amount of bytes read on success
 *                  0 in case the connection was closed
 *                  -1 if an error occurred
 */
ssize_t read_k_bytes(int sockfd, char *buff, size_t k){

    ssize_t read_bytes, total_read;
    read_bytes = 0;
    total_read = 0;

    while(k - total_read > 0){
        read_bytes = read(sockfd, buff + total_read, k - total_read);
        if (read_bytes > 0){
            total_read = total_read + read_bytes;
        }
        if (read_bytes == 0){
            return 0;
        }
        if (read_bytes == -1){
            return -1;
        }
    }

    return total_read;

}


/**
 * @brief Writes the the given k amount of bytes to the given socket from
 * the given buffer. 
 * Returns:
 *  k on success
 *  0 in case the connection was closed
 *  -1 if an error occurred
 * 
 * @param sockfd the fd of the socket
 * @param buf the buffer to write to
 * @param k amount of bytes to be written
 * @return ssize_t The amount of bytes written on success
 *                  0 in case the connection was closed
 *                  -1 if an error occurred
 */
ssize_t write_k_bytes(int sockfd, char *buff, size_t k){

    ssize_t written_bytes, total_written;
    written_bytes = 0;
    total_written = 0;
    while(k - total_written > 0){
        written_bytes = write(sockfd, buff + total_written, k - total_written);
        if (written_bytes > 0){
            total_written = total_written + written_bytes;
        }
        if (written_bytes == -1){
            if ((errno == ETIMEDOUT) || (errno == ECONNRESET) || (errno == EPIPE)){
                return 0;
            }
            return -1;
        }
    }

    return total_written;

}

/**
 * @brief returns the sum of the given array that counted the 
 * number of printable characters
 * 
 * @param pcc An array that counted the number of printable characters
 * @return uint32_t sum of the given array
 */
uint32_t num_of_pcc(uint32_t pcc[]){
    
    int i;
    uint32_t sum;
    sum = 0;
    for(i = 0; i < NUM_OF_PCC; i++){
        sum = sum + pcc[i];
    }
    return sum;

}

/**
 * @brief updated the total pcc counter array with the given array's
 * counts
 * 
 * @param pcc An array that counted the number of printable characters
 */
void update_total(uint32_t pcc[]){

    int i;
    for(i = 0; i < NUM_OF_PCC; i++){
        pcc_total[i] = pcc_total[i] + pcc[i];
    }
}






int main(int argc, char *argv[]){

    int sockfd, er, option_value, connfd, i, fail_flag;
    ssize_t read_bytes, written;
    char curr_c;
    uint16_t port;
    uint32_t file_size, data_buffer_size, N_buff;
    uint32_t pcc_amount, message;

    struct sockaddr_in serv_addr, peer_addr;
    socklen_t addrsize;
    char *data_buff;
    uint32_t connection_pcc_total[NUM_OF_PCC];


    // Input validity check
    if (argc != 2){
        fprintf(stderr, "Invalid arguments\n");
        exit(1);
    }

    // Setting up the connection
    port = atoi(argv[1]);
    sockfd = socket(AF_INET, SOCK_STREAM, 0);
    if(sockfd < 0){
        perror("Failed to initiate socket");
        exit(1);
    }
    option_value = 1;
    // Disabling the TIME_WAIT 
    er = setsockopt(sockfd, SOL_SOCKET, SO_REUSEADDR, &option_value, sizeof(option_value));
    if(er < 0){
        perror("Failed to disable TIME_WAIT");
        exit(1);
    }

    serv_addr.sin_family = AF_INET;
    serv_addr.sin_addr.s_addr = htonl(INADDR_ANY);
    serv_addr.sin_port = htons(port);
    addrsize = sizeof(struct sockaddr_in);

    er = bind(sockfd, (struct sockaddr *)&serv_addr, addrsize);
    if(er < 0){
        perror("Failed to bind socket");
        exit(1);
    }

    // Waiting for connection and connecting
    er = listen(sockfd, LISTEN_QUEUE_SIZE);
    if(er < 0){
        perror("Failed to initiate listening state");
        exit(1);
    }

    // Initializing the data buffer
    data_buff = malloc(MAX_BUFF_SIZE);
    if(data_buff == NULL){
        fprintf(stderr, "Failed to allocate buffer for data transfer\n");
        exit(1);
    }
    // Starting to accept and handle connections
    while(1){
        // Resetting current connection pcc counter and fail_flag
        memset(connection_pcc_total, 0, sizeof(connection_pcc_total));
        fail_flag = 0;

        // Connecting
        connfd = accept(sockfd, (struct sockaddr *)&peer_addr, &addrsize);

        if(connfd < 0){
            perror("Failed to accept connection");
            exit(1);
        }
        // ====== Reading data ======

        // Reding the header to know the file size
        read_bytes = read_k_bytes(connfd, (char *)&N_buff, sizeof(N_buff));
        if(read_bytes < 0){
            // todo: handle this
            if ((errno != ETIMEDOUT) && (errno != ECONNRESET) && (errno != EPIPE)){
                fprintf(stderr, "%s\n", strerror(errno));

            }
        }
        // Reading the file stream
        if (read_bytes == N){
            file_size = ntohl(N_buff);
            
            while (file_size> 0){
                data_buffer_size = MIN(file_size, MAX_BUFF_SIZE);
                read_bytes = read_k_bytes(connfd, data_buff, data_buffer_size);
                
                if(read_bytes <= 0){
                        if(read_bytes < 0){
                            // todo: handle this
                            if ((errno != ETIMEDOUT) && (errno != ECONNRESET) && (errno != EPIPE)){
                                fprintf(stderr, "%s\n", strerror(errno));

                            }
                    }
                    fail_flag = 1;
                    break;
                }
                // Updating current connection pcc total
                for (i = 0; i < read_bytes; i ++){
                    curr_c = data_buff[i];
                    if ((32 <=curr_c) && (curr_c <= 126)){
                        connection_pcc_total[curr_c - PCC_OFFSET]++;
                    }
                }
                file_size = file_size - read_bytes;
            }            
        }


        // ====== Writing data ======

        if(!fail_flag){
            pcc_amount = num_of_pcc(connection_pcc_total);
            message = htonl(pcc_amount);
            written = write_k_bytes(connfd, (char *)&message, sizeof(message));
            if(written != (ssize_t)sizeof(message)){
                if(written < 0){
                    fprintf(stderr, "%s\n", strerror(errno));
                }
                fail_flag = 1;
            } 
        }
        

        if(!fail_flag){
            update_total(connection_pcc_total);
        }

        er = close(connfd);
        if(er < 0){
            perror("Failed to close socket");
            exit(1);
        }
    }



      
}

    

