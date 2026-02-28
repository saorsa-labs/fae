#ifndef SQLITE_VEC_INIT_H
#define SQLITE_VEC_INIT_H

#include <sqlite3.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Register sqlite-vec extension on a specific database connection.
/// Must be called after opening each connection.
/// Apple's system SQLite deprecates sqlite3_auto_extension,
/// so we register per-connection instead.
int sqlite_vec_register(sqlite3 *db);

#ifdef __cplusplus
}
#endif

#endif /* SQLITE_VEC_INIT_H */
