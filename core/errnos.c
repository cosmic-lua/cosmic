/*
 * The errno table core/errnos.h describes. Its entries and their order
 * are musl's (src/errno/__strerror.h, as the pinned zig carries it;
 * musl is MIT, and in the bill of materials), so a Linux core answers
 * exactly what musl's strerror did, and a macOS core the same words
 * rather than libSystem's. An entry this OS's <errno.h> does not name
 * is left out. EOPNOTSUPP is added ahead of ENOTSUP, which musl lists
 * alone since Linux gives both one number; macOS gives them two. The
 * entries after musl's name what it does not (see there).
 */

#include "errnos.h"

#include <errno.h>
#include <stddef.h>

struct errno_entry {
  int number;
  const char *name;
  const char *message;
};

static const struct errno_entry entries[] = {
#ifdef EILSEQ
  {EILSEQ, "EILSEQ", "Illegal byte sequence"},
#endif
#ifdef EDOM
  {EDOM, "EDOM", "Domain error"},
#endif
#ifdef ERANGE
  {ERANGE, "ERANGE", "Result not representable"},
#endif
#ifdef ENOTTY
  {ENOTTY, "ENOTTY", "Not a tty"},
#endif
#ifdef EACCES
  {EACCES, "EACCES", "Permission denied"},
#endif
#ifdef EPERM
  {EPERM, "EPERM", "Operation not permitted"},
#endif
#ifdef ENOENT
  {ENOENT, "ENOENT", "No such file or directory"},
#endif
#ifdef ESRCH
  {ESRCH, "ESRCH", "No such process"},
#endif
#ifdef EEXIST
  {EEXIST, "EEXIST", "File exists"},
#endif
#ifdef EOVERFLOW
  {EOVERFLOW, "EOVERFLOW", "Value too large for data type"},
#endif
#ifdef ENOSPC
  {ENOSPC, "ENOSPC", "No space left on device"},
#endif
#ifdef ENOMEM
  {ENOMEM, "ENOMEM", "Out of memory"},
#endif
#ifdef EBUSY
  {EBUSY, "EBUSY", "Resource busy"},
#endif
#ifdef EINTR
  {EINTR, "EINTR", "Interrupted system call"},
#endif
#ifdef EAGAIN
  {EAGAIN, "EAGAIN", "Resource temporarily unavailable"},
#endif
#ifdef ESPIPE
  {ESPIPE, "ESPIPE", "Invalid seek"},
#endif
#ifdef EXDEV
  {EXDEV, "EXDEV", "Cross-device link"},
#endif
#ifdef EROFS
  {EROFS, "EROFS", "Read-only file system"},
#endif
#ifdef ENOTEMPTY
  {ENOTEMPTY, "ENOTEMPTY", "Directory not empty"},
#endif
#ifdef ECONNRESET
  {ECONNRESET, "ECONNRESET", "Connection reset by peer"},
#endif
#ifdef ETIMEDOUT
  {ETIMEDOUT, "ETIMEDOUT", "Operation timed out"},
#endif
#ifdef ECONNREFUSED
  {ECONNREFUSED, "ECONNREFUSED", "Connection refused"},
#endif
#ifdef EHOSTDOWN
  {EHOSTDOWN, "EHOSTDOWN", "Host is down"},
#endif
#ifdef EHOSTUNREACH
  {EHOSTUNREACH, "EHOSTUNREACH", "Host is unreachable"},
#endif
#ifdef EADDRINUSE
  {EADDRINUSE, "EADDRINUSE", "Address in use"},
#endif
#ifdef EPIPE
  {EPIPE, "EPIPE", "Broken pipe"},
#endif
#ifdef EIO
  {EIO, "EIO", "I/O error"},
#endif
#ifdef ENXIO
  {ENXIO, "ENXIO", "No such device or address"},
#endif
#ifdef ENOTBLK
  {ENOTBLK, "ENOTBLK", "Block device required"},
#endif
#ifdef ENODEV
  {ENODEV, "ENODEV", "No such device"},
#endif
#ifdef ENOTDIR
  {ENOTDIR, "ENOTDIR", "Not a directory"},
#endif
#ifdef EISDIR
  {EISDIR, "EISDIR", "Is a directory"},
#endif
#ifdef ETXTBSY
  {ETXTBSY, "ETXTBSY", "Text file busy"},
#endif
#ifdef ENOEXEC
  {ENOEXEC, "ENOEXEC", "Exec format error"},
#endif
#ifdef EINVAL
  {EINVAL, "EINVAL", "Invalid argument"},
#endif
#ifdef E2BIG
  {E2BIG, "E2BIG", "Argument list too long"},
#endif
#ifdef ELOOP
  {ELOOP, "ELOOP", "Symbolic link loop"},
#endif
#ifdef ENAMETOOLONG
  {ENAMETOOLONG, "ENAMETOOLONG", "Filename too long"},
#endif
#ifdef ENFILE
  {ENFILE, "ENFILE", "Too many open files in system"},
#endif
#ifdef EMFILE
  {EMFILE, "EMFILE", "No file descriptors available"},
#endif
#ifdef EBADF
  {EBADF, "EBADF", "Bad file descriptor"},
#endif
#ifdef ECHILD
  {ECHILD, "ECHILD", "No child process"},
#endif
#ifdef EFAULT
  {EFAULT, "EFAULT", "Bad address"},
#endif
#ifdef EFBIG
  {EFBIG, "EFBIG", "File too large"},
#endif
#ifdef EMLINK
  {EMLINK, "EMLINK", "Too many links"},
#endif
#ifdef ENOLCK
  {ENOLCK, "ENOLCK", "No locks available"},
#endif
#ifdef EDEADLK
  {EDEADLK, "EDEADLK", "Resource deadlock would occur"},
#endif
#ifdef ENOTRECOVERABLE
  {ENOTRECOVERABLE, "ENOTRECOVERABLE", "State not recoverable"},
#endif
#ifdef EOWNERDEAD
  {EOWNERDEAD, "EOWNERDEAD", "Previous owner died"},
#endif
#ifdef ECANCELED
  {ECANCELED, "ECANCELED", "Operation canceled"},
#endif
#ifdef ENOSYS
  {ENOSYS, "ENOSYS", "Function not implemented"},
#endif
#ifdef ENOMSG
  {ENOMSG, "ENOMSG", "No message of desired type"},
#endif
#ifdef EIDRM
  {EIDRM, "EIDRM", "Identifier removed"},
#endif
#ifdef ENOSTR
  {ENOSTR, "ENOSTR", "Device not a stream"},
#endif
#ifdef ENODATA
  {ENODATA, "ENODATA", "No data available"},
#endif
#ifdef ETIME
  {ETIME, "ETIME", "Device timeout"},
#endif
#ifdef ENOSR
  {ENOSR, "ENOSR", "Out of streams resources"},
#endif
#ifdef ENOLINK
  {ENOLINK, "ENOLINK", "Link has been severed"},
#endif
#ifdef EPROTO
  {EPROTO, "EPROTO", "Protocol error"},
#endif
#ifdef EBADMSG
  {EBADMSG, "EBADMSG", "Bad message"},
#endif
#ifdef EBADFD
  {EBADFD, "EBADFD", "File descriptor in bad state"},
#endif
#ifdef ENOTSOCK
  {ENOTSOCK, "ENOTSOCK", "Not a socket"},
#endif
#ifdef EDESTADDRREQ
  {EDESTADDRREQ, "EDESTADDRREQ", "Destination address required"},
#endif
#ifdef EMSGSIZE
  {EMSGSIZE, "EMSGSIZE", "Message too large"},
#endif
#ifdef EPROTOTYPE
  {EPROTOTYPE, "EPROTOTYPE", "Protocol wrong type for socket"},
#endif
#ifdef ENOPROTOOPT
  {ENOPROTOOPT, "ENOPROTOOPT", "Protocol not available"},
#endif
#ifdef EPROTONOSUPPORT
  {EPROTONOSUPPORT, "EPROTONOSUPPORT", "Protocol not supported"},
#endif
#ifdef ESOCKTNOSUPPORT
  {ESOCKTNOSUPPORT, "ESOCKTNOSUPPORT", "Socket type not supported"},
#endif
#ifdef EOPNOTSUPP
  {EOPNOTSUPP, "EOPNOTSUPP", "Not supported"},
#endif
#ifdef ENOTSUP
  {ENOTSUP, "ENOTSUP", "Not supported"},
#endif
#ifdef EPFNOSUPPORT
  {EPFNOSUPPORT, "EPFNOSUPPORT", "Protocol family not supported"},
#endif
#ifdef EAFNOSUPPORT
  {EAFNOSUPPORT, "EAFNOSUPPORT", "Address family not supported by protocol"},
#endif
#ifdef EADDRNOTAVAIL
  {EADDRNOTAVAIL, "EADDRNOTAVAIL", "Address not available"},
#endif
#ifdef ENETDOWN
  {ENETDOWN, "ENETDOWN", "Network is down"},
#endif
#ifdef ENETUNREACH
  {ENETUNREACH, "ENETUNREACH", "Network unreachable"},
#endif
#ifdef ENETRESET
  {ENETRESET, "ENETRESET", "Connection reset by network"},
#endif
#ifdef ECONNABORTED
  {ECONNABORTED, "ECONNABORTED", "Connection aborted"},
#endif
#ifdef ENOBUFS
  {ENOBUFS, "ENOBUFS", "No buffer space available"},
#endif
#ifdef EISCONN
  {EISCONN, "EISCONN", "Socket is connected"},
#endif
#ifdef ENOTCONN
  {ENOTCONN, "ENOTCONN", "Socket not connected"},
#endif
#ifdef ESHUTDOWN
  {ESHUTDOWN, "ESHUTDOWN", "Cannot send after socket shutdown"},
#endif
#ifdef EALREADY
  {EALREADY, "EALREADY", "Operation already in progress"},
#endif
#ifdef EINPROGRESS
  {EINPROGRESS, "EINPROGRESS", "Operation in progress"},
#endif
#ifdef ESTALE
  {ESTALE, "ESTALE", "Stale file handle"},
#endif
#ifdef EREMOTEIO
  {EREMOTEIO, "EREMOTEIO", "Remote I/O error"},
#endif
#ifdef EDQUOT
  {EDQUOT, "EDQUOT", "Quota exceeded"},
#endif
#ifdef ENOMEDIUM
  {ENOMEDIUM, "ENOMEDIUM", "No medium found"},
#endif
#ifdef EMEDIUMTYPE
  {EMEDIUMTYPE, "EMEDIUMTYPE", "Wrong medium type"},
#endif
#ifdef EMULTIHOP
  {EMULTIHOP, "EMULTIHOP", "Multihop attempted"},
#endif
#ifdef ENOKEY
  {ENOKEY, "ENOKEY", "Required key not available"},
#endif
#ifdef EKEYEXPIRED
  {EKEYEXPIRED, "EKEYEXPIRED", "Key has expired"},
#endif
#ifdef EKEYREVOKED
  {EKEYREVOKED, "EKEYREVOKED", "Key has been revoked"},
#endif
#ifdef EKEYREJECTED
  {EKEYREJECTED, "EKEYREJECTED", "Key was rejected by service"},
#endif
  /* After musl's: the errnos it has no words for. The first nineteen
   * are macOS's own, in libSystem's words -- a spawned file of the
   * wrong architecture fails with EBADARCH -- and the last three, which
   * both OSes name, in glibc's. */
#ifdef EAUTH
  {EAUTH, "EAUTH", "Authentication error"},
#endif
#ifdef EBADARCH
  {EBADARCH, "EBADARCH", "Bad CPU type in executable"},
#endif
#ifdef EBADEXEC
  {EBADEXEC, "EBADEXEC", "Bad executable (or shared library)"},
#endif
#ifdef EBADMACHO
  {EBADMACHO, "EBADMACHO", "Malformed Mach-o file"},
#endif
#ifdef EBADRPC
  {EBADRPC, "EBADRPC", "RPC struct is bad"},
#endif
#ifdef EDEVERR
  {EDEVERR, "EDEVERR", "Device error"},
#endif
#ifdef EFTYPE
  {EFTYPE, "EFTYPE", "Inappropriate file type or format"},
#endif
#ifdef ENEEDAUTH
  {ENEEDAUTH, "ENEEDAUTH", "Need authenticator"},
#endif
#ifdef ENOATTR
  {ENOATTR, "ENOATTR", "Attribute not found"},
#endif
#ifdef ENOPOLICY
  {ENOPOLICY, "ENOPOLICY", "Policy not found"},
#endif
#ifdef ENOTCAPABLE
  {ENOTCAPABLE, "ENOTCAPABLE", "Capabilities insufficient"},
#endif
#ifdef EPROCLIM
  {EPROCLIM, "EPROCLIM", "Too many processes"},
#endif
#ifdef EPROCUNAVAIL
  {EPROCUNAVAIL, "EPROCUNAVAIL", "Bad procedure for program"},
#endif
#ifdef EPROGMISMATCH
  {EPROGMISMATCH, "EPROGMISMATCH", "Program version wrong"},
#endif
#ifdef EPROGUNAVAIL
  {EPROGUNAVAIL, "EPROGUNAVAIL", "RPC prog. not avail"},
#endif
#ifdef EPWROFF
  {EPWROFF, "EPWROFF", "Device power is off"},
#endif
#ifdef EQFULL
  {EQFULL, "EQFULL", "Interface output queue is full"},
#endif
#ifdef ERPCMISMATCH
  {ERPCMISMATCH, "ERPCMISMATCH", "RPC version wrong"},
#endif
#ifdef ESHLIBVERS
  {ESHLIBVERS, "ESHLIBVERS", "Shared library version mismatch"},
#endif
#ifdef EREMOTE
  {EREMOTE, "EREMOTE", "Object is remote"},
#endif
#ifdef ETOOMANYREFS
  {ETOOMANYREFS, "ETOOMANYREFS", "Too many references: cannot splice"},
#endif
#ifdef EUSERS
  {EUSERS, "EUSERS", "Too many users"},
#endif
};

const char *cosmic_errno_describe (int number, const char **name) {
  for (size_t i = 0; i < sizeof entries / sizeof *entries; i++) {
    if (entries[i].number == number) {
      if (name != NULL) *name = entries[i].name;
      return entries[i].message;
    }
  }
  if (name != NULL) *name = NULL;
  return "No error information";
}
