#ifdef __cplusplus
extern "C" {
#endif

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "moonbit.h"

MOONBIT_FFI_EXPORT void *
moonlint_popen(const char *cmd, const char *mode) {
  return popen(cmd, mode);
}

MOONBIT_FFI_EXPORT int
moonlint_pclose(void *pipe) {
  return pclose((FILE *)pipe);
}

MOONBIT_FFI_EXPORT int
moonlint_pipe_is_null(void *ptr) {
  return ptr == NULL;
}

MOONBIT_FFI_EXPORT char *
moonlint_fgets(char *buf, int size, void *stream) {
  return fgets(buf, size, (FILE *)stream);
}

#ifdef __cplusplus
}
#endif
