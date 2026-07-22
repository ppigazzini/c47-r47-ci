#ifndef FC_STUB_EXECINFO_H
#define FC_STUB_EXECINFO_H
int backtrace(void **, int);
char **backtrace_symbols(void *const *, int);
void backtrace_symbols_fd(void *const *, int, int);
#endif
