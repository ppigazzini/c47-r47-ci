#ifndef FC_STUB_DLFCN_H
#define FC_STUB_DLFCN_H
void *dlopen(const char *, int); void *dlsym(void *, const char *);
int dlclose(void *); char *dlerror(void);
#define RTLD_LAZY 1
#define RTLD_NOW 2
#endif
