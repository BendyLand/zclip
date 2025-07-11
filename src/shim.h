#pragma once

#include <sys/select.h>

void z_fd_zero(fd_set* set);
void z_fd_set(int fd, fd_set* set);
int z_fd_isset(int fd, fd_set* set);

