#ifndef ZIO_H
#define ZIO_H

typedef int                ZIO_INT;
typedef char               ZIO_CHAR;
typedef void               ZIO_VOID;
typedef unsigned short     ZIO_USHORT;
typedef unsigned long long ZIO_USIZE;

typedef enum {
    ZIO_EVENT_READ  = 1,
    ZIO_EVENT_WRITE = 2,
    ZIO_EVENT_RESET = 4,
} ZIO_EVENT_TYPE;

typedef enum {
    ZIO_RESULT_OK       = 0,
    ZIO_RESULT_ERROR    = 1,
    ZIO_RESULT_RETRY    = 2,
    ZIO_RESULT_REGISTER = 3,
} ZIO_RESULT;

typedef struct {
    ZIO_EVENT_TYPE Event;
    ZIO_USIZE BytesTransferred;
} ZIO_RESULT_INFO;

typedef struct ZIO_OVERLAPPED ZIO_OVERLAPPED;

static ZIO_RESULT ZioOverlappedContext(
    ZIO_OVERLAPPED* Overlapped,
    ZIO_EVENT_TYPE Context,
    ZIO_OVERLAPPED* Other,
);

typedef struct ZIO_EVENT ZIO_EVENT;

typedef struct {
    ZIO_VOID* UserInfo;
    ZIO_USIZE BytesTransferred;
    ZIO_OVERLAPPED* Overlapped;
} ZIO_EVENT_INFO;

ZIO_RESULT ZioEventGetResult(
    ZIO_EVENT* Event,
    ZIO_EVENT_INFO* Info,
);

typedef struct ZIO_HANDLE ZIO_HANDLE;

typedef enum {
    ZIO_SELECTOR_CREATE = 0,
    ZIO_SELECTOR_MODIFY = 1,
    ZIO_SELECTOR_DELETE = 2, 
} ZIO_SELECTOR_OP;

ZIO_HANDLE ZioSelector();

ZIO_RESULT ZioSelectorClose(
    ZIO_HANDLE Selector,
);

ZIO_RESULT ZioSelectorRegister(
    ZIO_SELECTOR_OP Operation,
    ZIO_HANDLE Selector,
    ZIO_HANDLE Handle,
    ZIO_EVENT_TYPE Events,
    ZIO_VOID* UserData,
);

ZIO_INT ZioSelectorPoll(
    ZIO_HANDLE Selector,
    ZIO_EVENT* Events,
    ZIO_USIZE NumEvents,
    ZIO_USIZE Timeout,
);

typedef struct ZIO_BUFFER ZIO_BUFFER;

ZIO_RESULT ZioBufferInit(
    ZIO_BUFFER* Buffer,
    ZIO_VOID* Data,
    ZIO_USIZE Size,
);

typedef enum {
    ZIO_AF_RAW   = 0,
    ZIO_AF_INET  = 1,
    ZIO_AF_INET6 = 2,
} ZIO_SOCKET_ADDRESS_FAMILY;

typedef struct ZIO_SOCKADDR ZIO_SOCKADDR;
typedef struct ZIO_SOCKADDR_IN ZIO_SOCKADDR_IN;
typedef struct ZIO_SOCKADDR_IN6 ZIO_SOCKADDR_IN6;

typedef struct ZIO_IN_ADDR ZIO_IN_ADDR;
typedef struct ZIO_IN_ADDR6 ZIO_IN_ADDR6;

ZIO_RESULT ZioSocketAddressInit(
    ZIO_SOCKADDR_IN* Address,
    ZIO_SOCKET_ADDRESS_FAMILY Family,
    ZIO_IN_ADDR IpAddress,
    ZIO_USHORT IpPort,
);

ZIO_RESULT ZioSocketAddressInit6(
    ZIO_SOCKADDR_IN* Address,
    ZIO_SOCKET_ADDRESS_FAMILY Family,
    ZIO_IN_ADDR6 IpAddress,
    ZIO_USHORT IpPort,
    ZIO_UINT FlowInfo,
    ZIO_UINT ScopeID,
);

ZIO_USIZE ZioParseAddress(
    ZIO_VOID* Address,
    ZIO_SOCKET_ADDRESS_FAMILY Family,
    ZIO_CHAR* String,
    ZIO_USIZE StringSize,
);


typedef enum {
    ZIO_SOCK_RAW = 0,
    ZIO_SOCK_TCP = 1,
    ZIO_SOCK_UDP = 2,
} ZIO_SOCKET_PROTOCOL;

typedef enum {
    ZIO_SOL_SOCKET = 0,
    ZIO_SOL_TCP    = 1,
} ZIO_SOCKET_LEVEL;

typedef enum {
    ZIO_SO_DEBUG,
    ZIO_SO_LINGER,
    ZIO_SO_SNDBUF,
    ZIO_SO_RCVBUF,
    ZIO_SO_SNDTIMEO,
    ZIO_SO_RCVTIMEO,
    ZIO_SO_DONTROUTE,
    ZIO_SO_BROADCAST,
    ZIO_SO_REUSEADDR,
    ZIO_SO_KEEPALIVE,
    ZIO_SO_OOBINLINE,

    ZIO_TCP_NODELAY,
    ZIO_TCP_KEEPCNT,
    ZIO_TCP_KEEPIDLE,
} ZIO_SOCKET_OPTION;


ZIO_RESULT ZioSocketBackendInit();

ZIO_RESULT ZioSocketBackendDestroy();

ZIO_HANDLE ZioSocket(
    ZIO_SOCKET_ADDRESS_FAMILY Family,
    ZIO_SOCKET_PROTOCOL Protocol,
    ZIO_HANDLE Selector,
);

ZIO_RESULT ZioSocketClose(
    ZIO_HANDLE Socket,
);

ZIO_RESULT ZioSocketRead(
    ZIO_HANDLE Socket,
    ZIO_BUFFER* Buffers,
    ZIO_USIZE NumBuffers,
    ZIO_SOCKADDR* Address,
    ZIO_USIZE AddressSize,
    ZIO_OVERLAPPED* Overlapped,
    ZIO_RESULT_INFO* ResultInfo,
);

ZIO_RESULT ZioSocketWrite(
    ZIO_HANDLE Socket,
    ZIO_BUFFER* Buffers,
    ZIO_USIZE NumBuffers,
    ZIO_SOCKADDR* Address,
    ZIO_USIZE AddressSize,
    ZIO_OVERLAPPED* Overlapped,
    ZIO_RESULT_INFO* ResultInfo,
);

ZIO_RESULT ZioSocketSendFile(
    ZIO_HANDLE Socket,
    ZIO_HANDLE File,
    ZIO_USIZE NumBytes,
    ZIO_OVERLAPPED* Overlapped,
    ZIO_RESULT_INFO* ResultInfo,
);

ZIO_RESULT ZioSocketConnect(
    ZIO_HANDLE Socket,
    ZIO_SOCKADDR* Address,
    ZIO_USIZE AddressSize,
    ZIO_OVERLAPPED* Overlapped,
);

ZIO_RESULT ZioSocketAccept(
    ZIO_HANDLE Socket,
    ZIO_HANDLE* Incoming,
    ZIO_SOCKADDR* Address,
    ZIO_USIZE AddressSize,
    ZIO_OVERLAPPED* Overlapped,
);

ZIO_RESULT ZioSocketBind(
    ZIO_HANDLE Socket,
    ZIO_SOCKADDR* Address,
    ZIO_USIZE AddressSize,
);

ZIO_RESULT ZioSocketListen(
    ZIO_HANDLE Socket,
    ZIO_USIZE Backlog,
);

ZIO_RESULT ZioSocketOption(
    ZIO_HANDLE Socket,
    ZIO_SOCKET_LEVEL Level,
    ZIO_SOCKET_OPTION Option,
    ZIO_VOID* OptionValue,
    ZIO_USIZE OptionSize,
);

#if defined(__DragonFly__) || defined(__FreeBSD__) || defined(__NetBSD__) || defined(__OpenBSD__) || defined(__APPLE__) || defined(__MACH__)
    #include "zio_kqueue.h"
#elif defined(_WIN32) || defined(WIN32) || defined(_WIN64) || defined(WIN64)
    #include "zio_iocp.h"
#elif defined(__linux__) || defined(linux)
    #include "zio_epoll.h"
#else
    #error "[ZIO] Platform not supported"
#endif

#endif // ZIO_H