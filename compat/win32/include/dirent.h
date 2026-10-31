// The directory operations used by the shared disk cache.
#pragma once
#include "gufo_posix.h"

struct dirent {
  char d_name[32768 * 4];
};
typedef struct gufo_directory DIR;
#ifdef __cplusplus
extern "C" {
#endif
DIR* fdopendir(int fd);
struct dirent* readdir(DIR* directory);
int closedir(DIR* directory);
#ifdef __cplusplus
}
#endif
