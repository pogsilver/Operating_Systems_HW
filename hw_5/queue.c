#include <stdlib.h>
#include <stdatomic.h>
#include <threads.h>



struct QNode{
    void* data;
    struct QNode* next;
};

struct QLinkedList{
   struct QNode* head;
   struct QNode* tail;

};

struct ThreadNode{
    cnd_t cnd;
    void* data;
    struct ThreadNode* next;
};

struct ThreadLinkedList{
   struct ThreadNode* head;
   struct ThreadNode* tail;

};

struct QLinkedList q;
struct ThreadLinkedList threads;
atomic_size_t numOfVisited;
mtx_t q_lock;

void initQueue(void){

    q = (struct QLinkedList){NULL, NULL};
    threads = (struct ThreadLinkedList){NULL, NULL};
    numOfVisited = 0;
    mtx_init(&q_lock, mtx_plain);
}

void destroyQueue(void){
    return;
}

void enqueue(void* data){

    mtx_lock(&q_lock);
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

void* dequeue(void){
    return;
}

size_t visited(void){
    return;
}