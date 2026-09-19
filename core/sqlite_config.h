/*
 * SQLite's compile-time configuration. The build is single-threaded and
 * the shipped database is read-only and opened through our own VFS, so
 * everything that exists for other shapes of use is off.
 */

#ifndef COSMIC_SQLITE_CONFIG_H
#define COSMIC_SQLITE_CONFIG_H

#define SQLITE_THREADSAFE 0
#define SQLITE_OMIT_LOAD_EXTENSION 1
#define SQLITE_OMIT_SHARED_CACHE 1
#define SQLITE_OMIT_DEPRECATED 1
#define SQLITE_OMIT_AUTOINIT 1
#define SQLITE_OMIT_PROGRESS_CALLBACK 1
#define SQLITE_OMIT_UTF16 1
#define SQLITE_DQS 0
#define SQLITE_DEFAULT_MEMSTATUS 0
#define SQLITE_DEFAULT_WAL_SYNCHRONOUS 1
#define SQLITE_LIKE_DOESNT_MATCH_BLOBS 1
#define SQLITE_MAX_EXPR_DEPTH 0
#define SQLITE_USE_ALLOCA 1
#define SQLITE_ENABLE_COLUMN_METADATA 1

/* The `dbstat` virtual table: what every table and index costs in
 * pages and bytes, which is what `cosmic db` reports. */
#define SQLITE_ENABLE_DBSTAT_VTAB 1

#endif
