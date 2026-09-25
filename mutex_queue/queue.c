#include <stdlib.h>
#include <stdatomic.h>
#include <threads.h>


/*Struct to store nodes in the queue*/
struct QNode{
    void* data;
    struct QNode* next;
};

/*A linked list that will be used to implement the queue*/
struct QLinkedList{
   struct QNode* head;
   struct QNode* tail;

};

/*Struct to store waiting threads*/
struct ThreadNode{
    cnd_t cnd;
    void* data;
    struct ThreadNode* next;
};

/*A linked list to store all the waiting threads that tried to dequeue but didn't
have an item to dequeue*/
struct ThreadLinkedList{
   struct ThreadNode* head;
   struct ThreadNode* tail;

};


struct QLinkedList q; // Our queue
struct ThreadLinkedList threads; // Our list of waiting threads. Will work in FIFO
atomic_size_t numOfVisited; // Tracks the number of items that have been both enqueued and dequeued
mtx_t q_lock;

/**
 * @brief Initializes the queue
 * 
 */
void initQueue(void){

    q = (struct QLinkedList){NULL, NULL};
    threads = (struct ThreadLinkedList){NULL, NULL};
    numOfVisited = 0;
    mtx_init(&q_lock, mtx_plain);
}

/**
 * @brief Cleans up the queue
 * 
 */
void destroyQueue(void){
    mtx_destroy(&q_lock);
}

/**
 * @brief Enqueues the given data. If there are no waiting threads, it will enqueue it directly to
 * the q queue. Otherwise, it will pass the given data directly to the longest waiting thread,
 * and removes it from the waiting threads list
 * 
 * @param data The data to enqueue
 */
void enqueue(void* data){

    mtx_lock(&q_lock);
    // Handle the case where there are waiting threads
    if (threads.head){
        threads.head->data = data;
        cnd_signal(&threads.head->cnd);
        threads.head = threads.head->next;
        if(!threads.head){
            threads.tail = NULL;
        }
    }
    else{
        struct QNode* newNode = malloc(sizeof(struct QNode));
        newNode->data = data;
        newNode->next = NULL;
        if(q.tail){
        q.tail->next = newNode;
        q.tail = newNode;
        }
        else{
            q.head = newNode;
            q.tail = newNode;
        }
    }
    mtx_unlock(&q_lock);
}

/**
 * @brief Dequeues the queue. If the queue is not empty, it will return the first inserted item to
 *  the queue. Otherwise, it will add a node t to the waiting threads list, and wait until
 * t's condition variable will be called upon. Then, it will return the value stored in t and free t's
 * memory
 * @return void* 
 */
void* dequeue(void){
    void* data;
    mtx_lock(&q_lock);

    // Handle non empty queue 
    if (q.head){
        struct QNode* currHead;
        currHead = q.head;
        data = q.head->data;
        q.head = q.head->next;
        if(!q.head){
            q.tail = NULL;
        }
        free(currHead);
    }
    else{
        struct ThreadNode *newThread;
        newThread = malloc(sizeof(struct ThreadNode));

        newThread->data = NULL;
        newThread->next = NULL;
        if(threads.tail){
            threads.tail->next = newThread;
            threads.tail = newThread;
        }
        else{
            threads.head = newThread;
            threads.tail = newThread;
        }

        cnd_init(&newThread->cnd);
        cnd_wait(&newThread->cnd, &q_lock);
        cnd_destroy(&newThread->cnd);
        data = newThread->data;
        free(newThread);
    }
    numOfVisited++;
    mtx_unlock(&q_lock);
    return data;
}

/**
 * @brief Returns the number of items that have been both enqueued and dequeued,
 * and is maintained without any locks 
 * 
 * @return size_t the number of items that have been both enqueued and dequeued
 */
size_t visited(void){
    return numOfVisited;
}