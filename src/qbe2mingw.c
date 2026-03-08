#include <stdio.h>
#include <string.h>
#include <stdlib.h>

int starts(const char *s,const char *p){return strncmp(s,p,strlen(p))==0;}

int main(){
    char line[4096];
    while(fgets(line,sizeof(line),stdin)){
        if(starts(line,"export function")){
            char name[256];
            char *a=strchr(line,'$');
            if(a){
                sscanf(a+1,"%255[^ (]",name);
                printf(".globl %s\n%s:\n",name,name);
            }
            continue;
        }
        if(strchr(line,'@')){
            char name[256];
            char *a=strchr(line,'@');
            sscanf(a+1,"%255[^:]:",name);
            printf("%s:\n",name);
            continue;
        }
        if(strstr(line,"ret")){
            printf("ret\n");
            continue;
        }
        if(strstr(line,"call")){
            char name[256];
            char *a=strchr(line,'$');
            if(a){
                sscanf(a+1,"%255[^ (]",name);
                printf("call %s\n",name);
            }
            continue;
        }
        if(strstr(line,"add")){
            printf("addq %%rbx, %%rax\n");
            continue;
        }
        if(strstr(line,"sub")){
            printf("subq %%rbx, %%rax\n");
            continue;
        }
        if(strstr(line,"mul")){
            printf("imul %%rbx, %%rax\n");
            continue;
        }
        if(strstr(line,"div")){
            printf("cqto\nidiv %%rbx\n");
            continue;
        }
    }
}