import JavaScriptCore

/// Implements the Node.js `constants` module (deprecated, re-exports OS/FS constants).
public struct ConstantsModule: NodeModule {
    public static let moduleName = "constants"

    @discardableResult
    public static func install(in context: JSContext, runtime: NodeRuntime) -> JSValue {
        let script = """
        (function() {
            var c = {};

            // File access constants (fs.constants)
            c.O_RDONLY = 0;
            c.O_WRONLY = 1;
            c.O_RDWR = 2;
            c.O_CREAT = 64;
            c.O_EXCL = 128;
            c.O_NOCTTY = 256;
            c.O_TRUNC = 512;
            c.O_APPEND = 1024;
            c.O_DIRECTORY = 65536;
            c.O_NOFOLLOW = 131072;
            c.O_SYNC = 1052672;
            c.O_DSYNC = 4096;
            c.O_NONBLOCK = 2048;

            // macOS-specific
            c.O_SYMLINK = 2097152;

            // File mode constants
            c.S_IFMT = 61440;
            c.S_IFREG = 32768;
            c.S_IFDIR = 16384;
            c.S_IFCHR = 8192;
            c.S_IFBLK = 24576;
            c.S_IFIFO = 4096;
            c.S_IFLNK = 40960;
            c.S_IFSOCK = 49152;
            c.S_IRWXU = 448;
            c.S_IRUSR = 256;
            c.S_IWUSR = 128;
            c.S_IXUSR = 64;
            c.S_IRWXG = 56;
            c.S_IRGRP = 32;
            c.S_IWGRP = 16;
            c.S_IXGRP = 8;
            c.S_IRWXO = 7;
            c.S_IROTH = 4;
            c.S_IWOTH = 2;
            c.S_IXOTH = 1;

            // File access constants for access()
            c.F_OK = 0;
            c.R_OK = 4;
            c.W_OK = 2;
            c.X_OK = 1;

            // Signal constants
            c.SIGHUP = 1;
            c.SIGINT = 2;
            c.SIGQUIT = 3;
            c.SIGILL = 4;
            c.SIGTRAP = 5;
            c.SIGABRT = 6;
            c.SIGBUS = 10;
            c.SIGFPE = 8;
            c.SIGKILL = 9;
            c.SIGUSR1 = 30;
            c.SIGUSR2 = 31;
            c.SIGSEGV = 11;
            c.SIGPIPE = 13;
            c.SIGALRM = 14;
            c.SIGTERM = 15;
            c.SIGCHLD = 20;
            c.SIGCONT = 19;
            c.SIGSTOP = 17;
            c.SIGTSTP = 18;
            c.SIGTTIN = 21;
            c.SIGTTOU = 22;
            c.SIGURG = 16;
            c.SIGXCPU = 24;
            c.SIGXFSZ = 25;
            c.SIGVTALRM = 26;
            c.SIGPROF = 27;
            c.SIGWINCH = 28;
            c.SIGIO = 23;
            c.SIGSYS = 12;

            // Errno constants
            c.E2BIG = 7;
            c.EACCES = 13;
            c.EADDRINUSE = 48;
            c.EADDRNOTAVAIL = 49;
            c.EAFNOSUPPORT = 47;
            c.EAGAIN = 35;
            c.EALREADY = 37;
            c.EBADF = 9;
            c.EBADMSG = 94;
            c.EBUSY = 16;
            c.ECANCELED = 89;
            c.ECHILD = 10;
            c.ECONNABORTED = 53;
            c.ECONNREFUSED = 61;
            c.ECONNRESET = 54;
            c.EDEADLK = 11;
            c.EDESTADDRREQ = 39;
            c.EDOM = 33;
            c.EDQUOT = 69;
            c.EEXIST = 17;
            c.EFAULT = 14;
            c.EFBIG = 27;
            c.EHOSTUNREACH = 65;
            c.EIDRM = 90;
            c.EILSEQ = 92;
            c.EINPROGRESS = 36;
            c.EINTR = 4;
            c.EINVAL = 22;
            c.EIO = 5;
            c.EISCONN = 56;
            c.EISDIR = 21;
            c.ELOOP = 62;
            c.EMFILE = 24;
            c.EMLINK = 31;
            c.EMSGSIZE = 40;
            c.EMULTIHOP = 95;
            c.ENAMETOOLONG = 63;
            c.ENETDOWN = 50;
            c.ENETRESET = 52;
            c.ENETUNREACH = 51;
            c.ENFILE = 23;
            c.ENOBUFS = 55;
            c.ENODATA = 96;
            c.ENODEV = 19;
            c.ENOENT = 2;
            c.ENOEXEC = 8;
            c.ENOLCK = 77;
            c.ENOLINK = 97;
            c.ENOMEM = 12;
            c.ENOMSG = 91;
            c.ENOPROTOOPT = 42;
            c.ENOSPC = 28;
            c.ENOSR = 98;
            c.ENOSTR = 99;
            c.ENOSYS = 78;
            c.ENOTCONN = 57;
            c.ENOTDIR = 20;
            c.ENOTEMPTY = 66;
            c.ENOTSOCK = 38;
            c.ENOTSUP = 45;
            c.ENOTTY = 25;
            c.ENXIO = 6;
            c.EOPNOTSUPP = 102;
            c.EOVERFLOW = 84;
            c.EPERM = 1;
            c.EPIPE = 32;
            c.EPROTO = 100;
            c.EPROTONOSUPPORT = 43;
            c.EPROTOTYPE = 41;
            c.ERANGE = 34;
            c.EROFS = 30;
            c.ESPIPE = 29;
            c.ESRCH = 3;
            c.ESTALE = 70;
            c.ETIME = 101;
            c.ETIMEDOUT = 60;
            c.ETXTBSY = 26;
            c.EWOULDBLOCK = 35;
            c.EXDEV = 18;

            return c;
        })();
        """

        return context.evaluateScript(script)!
    }
}
