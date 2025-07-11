#include "templates.h"

void z_fd_zero(fd_set* set)
{
    FD_ZERO(set);
}

void z_fd_set(int fd, fd_set* set)
{
    FD_SET(fd, set);
}

int z_fd_isset(int fd, fd_set* set)
{
    return FD_ISSET(fd, set);
}

