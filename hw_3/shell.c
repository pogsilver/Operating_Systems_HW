#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>

// arglist - a list of char* arguments (words) provided by the user
// it contains count+1 items, where the last item (arglist[count]) and *only* the last is NULL
// RETURNS - 1 if should continue, 0 otherwise
int process_arglist(int count, char** arglist);

// prepare and finalize calls for initialization and destruction of anything required
int prepare(void);
int finalize(void);

// Identify which case we need to handle
int case_identify(int count, char** arglist){

	int i;	
	if(strcmp(arglist[count - 1], "&")){
		return 1;
	}
	if(strcmp(arglist[count - 2], "<")){
		return 2;
	}
	if(strcmp(arglist[count - 2], ">")){
		return 3;
	}
	for(i = 0; i < count; i++){
		if(strcmp(arglist[i], "|")){
			return 4;
		}
	}
	return 0;
}

int prepare(void){
	/* SIGINT number is 2, SIG_IGN number is 1*/
	signal(2, 1);
	return 0;
}



int process_arglist(int count, char** arglist){

	int pid = fork();
	int status;
	
	switch(case_identify(count, arglist)){
		case 1:
		// &
		break;
		case 2:
		// <
		break;
		case 3:
		// >
		break;
		case 4:
		// |
		break;
		default:
		//No special case
		if(pid == -1){
			perror("Failed to execute process");
			return 0;
		}
	
		if (pid == 0){
			if(execvp(arglist[0], arglist) == -1){
				perror("Failed to execute process");
				exit(1);
			}
		}
		waitpid(pid, &status, 0);
		return 1;
	}



}

int main(void)
{
	if (prepare() != 0)
		exit(1);
	
	while (1)
	{
		char** arglist = NULL;
		char* line = NULL;
		size_t size;
		int count = 0;

		if (getline(&line, &size, stdin) == -1) {
			free(line);
			break;
		}
    
		arglist = (char**) malloc(sizeof(char*));
		if (arglist == NULL) {
			printf("malloc failed: %s\n", strerror(errno));
			exit(1);
		}
		arglist[0] = strtok(line, " \t\n");
    
		while (arglist[count] != NULL) {
			++count;
			arglist = (char**) realloc(arglist, sizeof(char*) * (count + 1));
			if (arglist == NULL) {
				printf("realloc failed: %s\n", strerror(errno));
				exit(1);
			}
      
			arglist[count] = strtok(NULL, " \t\n");
		}
    
		if (count != 0) {
			if (!process_arglist(count, arglist)) {
				free(line);
				free(arglist);
				break;
			}
		}
    
		free(line);
		free(arglist);
	}
	
	if (finalize() != 0)
		exit(1);

	return 0;
}
