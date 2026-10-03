#ifndef STREAM_STATUS_H
#define STREAM_STATUS_H

#include <stddef.h>

/* The menu-bar app and the terminal helper share this. 0 is playing,
 * 1 is waiting, 2 needs a look (quiet, missing BlackHole, wrong rate). */
int stream_play(void);
int stream_copy_status(char *menu, size_t menu_len, char *head, size_t head_len, char *body, size_t body_len);

#endif
