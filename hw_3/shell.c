#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <signal.h>
#include <unistd.h>
#include <sys/types.h>
#include <fcntl.h>
#include <sys/wait.h>

// arglist - a list of char* arguments (words) provided by the user
// it contains count+1 items, where the last item (arglist[count]) and *only* the last is NULL
// RETURNS - 1 if should continue, 0 otherwise
int process_arglist(int count, char** arglist);

// prepare and finalize calls for initialization and destruction of anything required
int prepare(void);
int finalize(void);

int prepare(void){
	signal(SIGINT, SIG_IGN);
	return 0;
}

/**
 * @brief 
 * Executes a process according to the given input
 * @param count the number of non NULL input words
 * @param arglist the string of input
 * @return int returns 0 on failure and 1 on success
 */
int execute_default(int count, char** arglist){
	int pid, status;
	pid = fork();
	if(pid == -1){
		perror("Failed to execute process");
		return 0;
	}

	if (pid == 0){
		// Changing the signal such that the child will terminate upon SIGINT
		signal(SIGINT, SIG_DFL);
		if(execvp(arglist[0], arglist) == -1){
			perror("Failed to execute process");
			exit(1);
		}
	}
	waitpid(pid, &status, 0);
	return 1;
}




/**
 * @brief 
 * Executes a background process according to the given input
 * @param count the number of non NULL input words
 * @param arglist the string of input
 * @return int returns 0 on failure and 1 on success
 */
int execute_background(int count, char** arglist){
	int pid;
	pid = fork();
	// Handle unsuccessful fork
	if(pid == -1){
		perror("Failed to launch background process");
		return 0;
	}
	if(pid == 0){
		// Updating the input and executing the process
		arglist[count - 1] = NULL;
		if(execvp(arglist[0], arglist) == -1){
			perror("Failed to execute process");
			exit(1);
		}
	}
	return 1;

}

/**
 * @brief 
 * Executes a process where the input is redirected from a given file\
 * according to the given input
 * @param count the number of non NULL input words
 * @param arglist the string of input
 * @return int returns 0 on failure and 1 on success
 */
int execute_input_redirection(int count, char** arglist){
	int pid, status, fd;
	char* file_path;

	pid = fork();
	if(pid == -1){
		perror("Failed to launch background process");
		return 0;
	}
	if(pid == 0){
		// Changing the signal such that the child will terminate upon SIGINT
		signal(SIGINT, SIG_DFL);

		// Setting the given file path as the input location
		file_path = arglist[count - 1];
		fd = open(file_path, O_RDONLY, S_IRUSR | S_IWUSR);
		if(fd == -1){
			perror("Failed to open given file path");
			exit(1);
		}
		if(dup2(fd, STDIN_FILENO) == -1){
			perror("Failed to redirect input from given file");
			close(fd);
			exit(1);
		}
		close(fd);

		// Updating the input and executing the process 
		arglist[count - 2] = NULL;
			if(execvp(arglist[0], arglist) == -1){
				perror("Failed to execute process");
				exit(1);
			}
	}
	waitpid(pid, &status, 0);
		return 1;
}

/**
 * @brief 
 * Executes a process where the output is redirected to a given file\
 * according to the given input
 * @param count the number of non NULL input words
 * @param arglist the string of input
 * @return int returns 0 on failure and 1 on success
 */
int execute_output_redirection(int count, char** arglist){
	int pid, status, fd;
	char* file_path;

	pid = fork();
	if(pid == -1){
		perror("Failed to launch background process");
		return 0;
	}
	if(pid == 0){
		// Changing the signal such that the child will terminate upon SIGINT
		signal(SIGINT, SIG_DFL);

		// Setting the given file path as the output location
		file_path = arglist[count - 1];
		fd = open(file_path, O_WRONLY | O_CREAT | O_TRUNC, S_IRUSR | S_IWUSR);
		if(fd == -1){
			perror("Failed to open given file path");
			exit(1);
		}
		if(dup2(fd, STDOUT_FILENO) == -1){
			perror("Failed to redirect output given path");
			close(fd);
			exit(1);
		}
		close(fd);

		// Updating the input and executing the process 
		arglist[count - 2] = NULL;
			if(execvp(arglist[0], arglist) == -1){
				perror("Failed to execute process");
				exit(1);
			}
	}
	waitpid(pid, &status, 0);
		return 1;
}

/**
 * @brief 
 * Executes a process according to the given input\
 * where piping is needed 
 * @param count the number of non NULL input words
 * @param arglist the string of input
 * @return int returns 0 on failure and 1 on success
 */
int execute_piping(int count, char** arglist){
	return 1;
}
int process_arglist(int count, char** arglist){

	int i;
	if((strcmp(arglist[count - 1], "&")) == 0){
		return execute_background(count, arglist);
	}
	if(count > 1){
		if((strcmp(arglist[count - 2], "<")) == 0){
			return execute_input_redirection(count, arglist);		
		}
		if((strcmp(arglist[count - 2], ">")) == 0){
			return execute_output_redirection(count, arglist);
		}
	}
	for(i = 0; i < count; i++){
		if((strcmp(arglist[i], "|")) == 0){
			return execute_piping(count, arglist);
		}
	}

	//No special case
	return execute_default(count, arglist);
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
