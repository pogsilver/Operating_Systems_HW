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


/**
 * @brief handles the sigchld signals to reap zombie processes
 * 
 * @param signum The signal number. activates only when signum == SIGCHLD
 */
void sigchld_handler(int signum){
	int i;
	if(signum == SIGCHLD){
		do{
			i = waitpid(-1, NULL, WNOHANG);
		}
		while( i > 0);
		if((i == -1) && (errno != ECHILD)){
			perror("Problem with the signal handler");
			exit(1);
		}
	}
}


int prepare(void){
	struct sigaction sa;
	// Handle SIGINT
	signal(SIGINT, SIG_IGN);
	// Handle zombies
	sa.sa_handler = sigchld_handler;
	sa.sa_flags = SA_RESTART | SA_NOCLDSTOP;
	if(sigaction(SIGCHLD, &sa, NULL) != 0){
		perror("Problem setting up the signal handler");
		exit(1);
	}
	return 0;
}

int finalize(void){
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
	pid_t pid;
	int status;
	pid = fork();
	if(pid == -1){
		perror("Failed to execute process");
		return 0;
	}

	if (pid == 0){
		// Changing the signal handling such that the child will terminate upon SIGINT
		signal(SIGINT, SIG_DFL);
		if(execvp(arglist[0], arglist) == -1){
			perror("Failed to execute process");
			exit(1);
		}
	}

	if(waitpid(pid, &status, 0) == -1){
		if((errno != ECHILD) && (errno != EINTR)){
			perror("ECHILD error in one of the processes");
			return 0;
		}
	}
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
	pid_t pid;
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
	int status, fd;
	pid_t pid;
	char* file_path;

	pid = fork();
	if(pid == -1){
		perror("Failed to launch background process");
		return 0;
	}
	if(pid == 0){
		// Changing the signal handling such that the child will terminate upon SIGINT
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
	if(waitpid(pid, &status, 0) == -1){
		if((errno != ECHILD) && (errno != EINTR)){
			perror("ECHILD error in one of the processes");
			return 0;
		}
	}
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
	int status, fd;
	pid_t pid;
	char* file_path;

	pid = fork();
	if(pid == -1){
		perror("Failed to launch background process");
		return 0;
	}
	if(pid == 0){
		// Changing the signal handling such that the child will terminate upon SIGINT
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
	if(waitpid(pid, &status, 0) == -1){
		if((errno != ECHILD) && (errno != EINTR)){
			perror("ECHILD error in one of the processes");
			return 0;
		}
	}
	return 1;
}

/**
 * @brief helper function to execute_piping. given an array of strings,\
 * the function modifies the array such that every instance of "|" is changed\
 * to NULL
 * 
 * @param count length of the array
 * @param arglist the array of strings that is modified
 */
void update_piping_array(int count, char** arglist){
	int i;
	for(i = 0; i < count; i++){
		if(strcmp(arglist[i], "|") == 0){
			arglist[i] = NULL;
		}
	}
}

/**
 * @brief a function to help find the index of the next child process\
 * arguments given the last one. Used in execute_piping after adjusting 
 * the input array
 * 
 * @param start index of the last process inputs
 * @param len length of the inputs array
 * @param arglist the array of inputs
 * @return int the index of the next process inputs in the array. returns -1\
 * if there is no next index
 */
int next_execute_index(int start, int len, char** arglist){

	while(start < len - 1){
		if((arglist[start] == NULL) && (arglist[start + 1] != NULL)){
			return start + 1;
		}
		start++;
	}
	return -1;
}
/**
 * @brief a helper function to execute_piping to count how many processes\
 * we need to run
 * @param len length of the input array
 * @param arglist the input array
 * @return int number of processes we need to run
 */
int count_commands(int len, char** arglist){
	int i, counter;
	counter = 0;
	for(i = 0; i < len; i++){
		if(strcmp(arglist[i], "|") == 0){
			counter++;
		}
	}
	return counter + 1;
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
	int num_of_commands, status, curr_exec, i, j;
	pid_t pid;
	num_of_commands = count_commands(count, arglist);
	
	pid_t pids[num_of_commands];
	curr_exec = 0;
	update_piping_array(count, arglist);
	int pipes_fd[num_of_commands - 1][2];

	// Setting up the pipes
	for(i = 0; i < num_of_commands - 1; i++){
		if(pipe(pipes_fd[i]) == -1){
			perror("Failed to initiate one of the pipes");
			return 0;
		}
	}

	for(i = 0; i < num_of_commands; i++){
		pid = fork();
		if(pid == -1){
			perror("Failed to execute one of the processes in the pipe");
			return 0;
		}
		pids[i] = pid;

		if(pid == 0){
			// Changing the signal handling such that the child will terminate upon SIGINT
			signal(SIGINT, SIG_DFL);

			//Mapping the pipes ends
			if(i != 0){
				if(dup2(pipes_fd[i-1][0], STDIN_FILENO) == -1){
					perror("Failed to use one of the pipes");
					exit(1);
				}
			}

			if(i != num_of_commands - 1){
				if(dup2(pipes_fd[i][1], STDOUT_FILENO) == -1){
					perror("Failed to use one of the pipes");
					exit(1);
				}
			}

			for(j = 0; j < num_of_commands - 1; j++){
				if((close(pipes_fd[j][0]) == -1) || (close(pipes_fd[j][1]) == -1)) {
					perror("Failed to use one of the pipes");
						exit(1);
				}	
			}

			if(execvp(arglist[curr_exec], arglist) == -1){
				perror("Failed to execute process");
				exit(1);
			}
		}

		curr_exec = next_execute_index(curr_exec, count, arglist);
	}

	// Handling the parent proccess
	for(j = 0; j < num_of_commands - 1; j++){
		if((close(pipes_fd[j][0]) == -1) || (close(pipes_fd[j][1]) == -1)) {
			perror("Failed to use one of the pipes");
				return 0;
		}	
	}

	for(j = 0; j < num_of_commands; j++){
		if(waitpid(pids[j], &status, 0) == -1){
			if((errno != ECHILD) && (errno != EINTR)){
				perror("ECHILD error in one of the processes");
				return 0;
			}
		}
	}
	return 1;
}
int process_arglist(int count, char** arglist){

	int i;
	if(strcmp(arglist[count - 1], "&") == 0){
		return execute_background(count, arglist);
	}
	if(count > 1){
		if(strcmp(arglist[count - 2], "<") == 0){
			return execute_input_redirection(count, arglist);		
		}
		if(strcmp(arglist[count - 2], ">") == 0){
			return execute_output_redirection(count, arglist);
		}
	}
	for(i = 0; i < count; i++){
		if(strcmp(arglist[i], "|") == 0){
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
