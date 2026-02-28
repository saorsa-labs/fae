#include "sqlite_vec_init.h"
#include "sqlite-vec.h"
#include <stddef.h>

int sqlite_vec_register(sqlite3 *db) {
    char *errmsg = NULL;
    return sqlite3_vec_init(db, &errmsg, NULL);
}
