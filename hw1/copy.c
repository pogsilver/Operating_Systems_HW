#include <stdio.h>
#include <stdlib.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>



int main(int argc, char *argv[]){

    int srcFile, dstFile, bufferSize;
    char *srcFilePath, *dstFilePath, *buffer;
    ssize_t readBytes, writtenBytes, currentWrittenBytes;
    
    /*Check the input is of expected length*/
    if (argc < 4){
        fprintf(stderr, "Unexpected number of inputs\n");
        exit(1);
    }

    srcFilePath = argv[1];
    dstFilePath = argv[2];
    sscanf(argv[3], "%d", &bufferSize);

    if (bufferSize <= 0){
        fprintf(stderr, "Illegal buffer size\n");
        exit(1);
    }

    /*Handle errors related to source and destination files before copying*/
    srcFile = open(srcFilePath, O_RDONLY);
    if (srcFile == -1){
        perror("Source file doesn't exist");
        exit(1);
    }

    dstFile = open(dstFilePath, O_RDONLY);
    if (dstFile != -1){
        fprintf(stderr, "Destination file already exists\n");
        close(srcFile);
        exit(1);
    }

    dstFile = open(dstFilePath, O_WRONLY | O_CREAT, S_IRUSR | S_IWUSR | S_IXUSR);
    if (dstFile == -1){
        perror("Couldn't create the destination file");
        close(srcFile);
        exit(1);
    }

    buffer = (char*) malloc(bufferSize);
    if (buffer == NULL){
        fprintf(stderr, "Couldn't allocate space for the buffer\n");
        close(srcFile);
        close(dstFile);
        free(buffer);
        exit(1);
    }

    readBytes = 1;
    /*Copying the source file into the destination file*/
    while(readBytes != 0){
        /*Reading the source file*/
        readBytes = read(srcFile, buffer, bufferSize);
        if (readBytes == -1){
            perror("Error reading from source file");
            close(srcFile);
            close(dstFile);
            free(buffer);
            exit(1);
        }
        /*Writing into the destination file, while makeing sure 
        all of the read bytes are written*/
        writtenBytes = 0;
        while(writtenBytes != readBytes){
            currentWrittenBytes = write(dstFile, buffer, readBytes - writtenBytes);
            if (currentWrittenBytes == -1){
                perror("Error writing to destination file");
                close(srcFile);
                close(dstFile);
                free(buffer);
                exit(1);
            }
            writtenBytes += currentWrittenBytes;
        }
    }
    close(srcFile);
    close(dstFile);
    free(buffer);
    exit(0);










    



}