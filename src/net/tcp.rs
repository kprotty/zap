use super::super::runtime::io::{IoFairness, IoKind, IoSource};
use std::{
    cell::RefCell,
    fmt,
    future::Future,
    io::{self, Read, Write},
    mem::MaybeUninit,
    net::SocketAddr,
    pin::Pin,
    sync::Arc,
    task::{Context, Poll, Waker},
};

pub struct TcpStream {
    source: IoSource<mio::net::TcpStream>,
    reader: RefCell<IoFairness>,
}

impl fmt::Debug for TcpStream {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("TcpStream").finish()
    }
}

unsafe impl Send for TcpStream {}
unsafe impl Sync for TcpStream {}

impl tokio::io::AsyncRead for TcpStream {
    fn poll_read(
        self: Pin<&mut Self>,
        ctx: &mut Context<'_>,
        buf: &mut tokio::io::ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        unsafe {
            let polled =
                self.reader
                    .borrow_mut()
                    .poll_io(&self.source, IoKind::Read, ctx.waker(), || {
                        let buf =
                            &mut *(buf.unfilled_mut() as *mut [MaybeUninit<u8>] as *mut [u8]);
                        self.source.as_ref().read(buf)
                    });

            match polled {
                Poll::Ready(Err(e)) => Poll::Ready(Err(e)),
                Poll::Pending => Poll::Pending,
                Poll::Ready(Ok(n)) => {
                    buf.assume_init(n);
                    buf.advance(n);
                    Poll::Ready(Ok(()))
                }
            }
        }
    }
}

impl tokio::io::AsyncWrite for TcpStream {
    fn poll_write(
        self: Pin<&mut Self>,
        ctx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        unsafe {
            self.source.poll_io(
                IoKind::Write,
                ctx.waker(),
                || false,
                || self.source.as_ref().write(buf),
            )
        }
    }

    fn poll_write_vectored(
        self: Pin<&mut Self>,
        ctx: &mut Context<'_>,
        bufs: &[io::IoSlice<'_>],
    ) -> Poll<io::Result<usize>> {
        unsafe {
            self.source.poll_io(
                IoKind::Write,
                ctx.waker(),
                || false,
                || self.source.as_ref().write_vectored(bufs),
            )
        }
    }

    fn is_write_vectored(&self) -> bool {
        true
    }

    fn poll_flush(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<io::Result<()>> {
        self.source.as_ref().flush()?;
        Poll::Ready(Ok(()))
    }

    fn poll_shutdown(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<io::Result<()>> {
        self.source.as_ref().shutdown(std::net::Shutdown::Write)?;
        Poll::Ready(Ok(()))
    }
}

impl TcpStream {
    fn new(stream: mio::net::TcpStream) -> Self {
        Self {
            source: IoSource::new(stream),
            reader: RefCell::new(IoFairness::default()),
        }
    }

    pub async fn connect(addr: SocketAddr) -> io::Result<Self> {
        let stream = mio::net::TcpStream::connect(addr)?;
        let this = Self::new(stream);

        unsafe {
            this.source.wait_for(IoKind::Write).await;
        }

        if let Some(e) = this.source.as_ref().take_error()? {
            return Err(e);
        }

        Ok(this)
    }

    pub fn split(self) -> (TcpReader, TcpWriter) {
        let stream = Arc::new(self);
        let reader = TcpReader {
            stream: stream.clone(),
        };
        let writer = TcpWriter {
            stream,
            do_shutdown: true,
        };

        (reader, writer)
    }

    fn reunite(reader: TcpReader, writer: TcpWriter) -> Result<Self, TcpReuniteError> {
        if Arc::ptr_eq(&reader.stream, &writer.stream) {
            writer.forget();
            Ok(Arc::try_unwrap(reader.stream).expect("Arc::try_unwrap failed on the same ptr"))
        } else {
            Err(TcpReuniteError(reader, writer))
        }
    }

    pub fn nodelay(&self) -> io::Result<bool> {
        self.source.as_ref().nodelay()
    }

    pub fn set_nodelay(&self, nodelay: bool) -> io::Result<()> {
        self.source.as_ref().set_nodelay(nodelay)
    }

    pub fn ttl(&self) -> io::Result<u32> {
        self.source.as_ref().ttl()
    }

    pub fn set_ttl(&self, ttl: u32) -> io::Result<()> {
        self.source.as_ref().set_ttl(ttl)
    }

    pub fn local_addr(&self) -> io::Result<SocketAddr> {
        self.source.as_ref().local_addr()
    }

    pub fn peer_addr(&self) -> io::Result<SocketAddr> {
        self.source.as_ref().peer_addr()
    }

    pub fn poll_peek(
        &self,
        ctx: &mut Context<'_>,
        buf: &mut tokio::io::ReadBuf<'_>,
    ) -> Poll<io::Result<usize>> {
        unsafe {
            let polled = self.reader.borrow_mut().poll_io(
                &self.source,
                IoKind::Read,
                ctx.waker(),
                || {
                    let buf = &mut *(buf.unfilled_mut() as *mut [MaybeUninit<u8>] as *mut [u8]);
                    self.source.as_ref().peek(buf)
                },
            );

            match polled {
                Poll::Ready(Err(e)) => Poll::Ready(Err(e)),
                Poll::Pending => Poll::Pending,
                Poll::Ready(Ok(n)) => {
                    buf.assume_init(n);
                    buf.advance(n);
                    Poll::Ready(Ok(n))
                }
            }
        }
    }
}

pub struct TcpReuniteError(pub TcpReader, pub TcpWriter);

pub struct TcpReader {
    stream: Arc<TcpStream>,
}

impl TcpReader {
    pub fn reunite(self, writer: TcpWriter) -> Result<TcpStream, TcpReuniteError> {
        TcpStream::reunite(self, writer)
    }

    pub fn poll_peek(
        &self,
        ctx: &mut Context<'_>,
        buf: &mut tokio::io::ReadBuf<'_>,
    ) -> Poll<io::Result<usize>> {
        unsafe {
            let polled = self.stream.reader.borrow_mut().poll_io(
                &self.stream.source,
                IoKind::Read,
                ctx.waker(),
                || {
                    let buf = &mut *(buf.unfilled_mut() as *mut [MaybeUninit<u8>] as *mut [u8]);
                    self.stream.source.as_ref().peek(buf)
                },
            );

            match polled {
                Poll::Ready(Err(e)) => Poll::Ready(Err(e)),
                Poll::Pending => Poll::Pending,
                Poll::Ready(Ok(n)) => {
                    buf.assume_init(n);
                    buf.advance(n);
                    Poll::Ready(Ok(n))
                }
            }
        }
    }
}

impl AsRef<TcpStream> for TcpReader {
    fn as_ref(&self) -> &TcpStream {
        &*self.stream
    }
}

impl tokio::io::AsyncRead for TcpReader {
    fn poll_read(
        self: Pin<&mut Self>,
        ctx: &mut Context<'_>,
        buf: &mut tokio::io::ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        unsafe {
            let polled = self.stream.reader.borrow_mut().poll_io(
                &self.stream.source,
                IoKind::Read,
                ctx.waker(),
                || {
                    let buf = &mut *(buf.unfilled_mut() as *mut [MaybeUninit<u8>] as *mut [u8]);
                    self.stream.source.as_ref().read(buf)
                },
            );

            match polled {
                Poll::Ready(Err(e)) => Poll::Ready(Err(e)),
                Poll::Pending => Poll::Pending,
                Poll::Ready(Ok(n)) => {
                    buf.assume_init(n);
                    buf.advance(n);
                    Poll::Ready(Ok(()))
                }
            }
        }
    }
}

pub struct TcpWriter {
    stream: Arc<TcpStream>,
    do_shutdown: bool,
}

impl Drop for TcpWriter {
    fn drop(&mut self) {
        if self.do_shutdown {
            let _ = self
                .stream
                .source
                .as_ref()
                .shutdown(std::net::Shutdown::Write);
        }
    }
}

impl TcpWriter {
    pub fn reunite(self, reader: TcpReader) -> Result<TcpStream, TcpReuniteError> {
        TcpStream::reunite(reader, self)
    }

    fn forget(mut self) {
        self.do_shutdown = false;
        std::mem::drop(self)
    }
}

impl AsRef<TcpStream> for TcpWriter {
    fn as_ref(&self) -> &TcpStream {
        &*self.stream
    }
}

impl tokio::io::AsyncWrite for TcpWriter {
    fn poll_write(
        self: Pin<&mut Self>,
        ctx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        unsafe {
            self.stream.source.poll_io(
                IoKind::Write,
                ctx.waker(),
                || false,
                || self.stream.source.as_ref().write(buf),
            )
        }
    }

    fn poll_write_vectored(
        self: Pin<&mut Self>,
        ctx: &mut Context<'_>,
        bufs: &[io::IoSlice<'_>],
    ) -> Poll<io::Result<usize>> {
        unsafe {
            self.stream.source.poll_io(
                IoKind::Write,
                ctx.waker(),
                || false,
                || self.stream.source.as_ref().write_vectored(bufs),
            )
        }
    }

    fn is_write_vectored(&self) -> bool {
        true
    }

    fn poll_flush(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<io::Result<()>> {
        self.stream.source.as_ref().flush()?;
        Poll::Ready(Ok(()))
    }

    fn poll_shutdown(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<io::Result<()>> {
        self.stream
            .source
            .as_ref()
            .shutdown(std::net::Shutdown::Write)?;
        Poll::Ready(Ok(()))
    }
}

pub struct TcpListener {
    source: IoSource<mio::net::TcpListener>,
    fairness: RefCell<IoFairness>,
}

unsafe impl Send for TcpListener {}
unsafe impl Sync for TcpListener {}

impl fmt::Debug for TcpListener {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("TcpListener").finish()
    }
}

impl TcpListener {
    pub fn bind(addr: SocketAddr) -> io::Result<Self> {
        let source = mio::net::TcpListener::bind(addr)?;
        Ok(Self {
            source: IoSource::new(source),
            fairness: RefCell::new(IoFairness::default()),
        })
    }

    pub fn accept<'a>(
        &'a mut self,
    ) -> impl Future<Output = io::Result<(TcpStream, SocketAddr)>> + 'a {
        struct Accept<'a> {
            listener: Option<&'a TcpListener>,
        }

        impl<'a> Drop for Accept<'a> {
            fn drop(&mut self) {
                if let Some(listener) = self.listener {
                    unsafe {
                        listener.source.detach_io(IoKind::Read);
                    }
                }
            }
        }

        impl<'a> Future for Accept<'a> {
            type Output = io::Result<(TcpStream, SocketAddr)>;

            fn poll(mut self: Pin<&mut Self>, ctx: &mut Context<'_>) -> Poll<Self::Output> {
                let listener = self.listener.expect("Accept polled after completion");
                let polled = unsafe { listener.poll_accept_inner(ctx.waker()) };

                match polled {
                    Poll::Pending => Poll::Pending,
                    Poll::Ready(result) => {
                        self.listener = None;
                        Poll::Ready(result)
                    }
                }
            }
        }

        Accept {
            listener: Some(self),
        }
    }

    pub fn poll_accept(
        self: Pin<&mut Self>,
        ctx: &mut Context<'_>,
    ) -> Poll<io::Result<(TcpStream, SocketAddr)>> {
        unsafe { self.poll_accept_inner(ctx.waker()) }
    }

    unsafe fn poll_accept_inner(&self, waker: &Waker) -> Poll<io::Result<(TcpStream, SocketAddr)>> {
        self.fairness
            .borrow_mut()
            .poll_io(&self.source, IoKind::Read, waker, || {
                self.source
                    .as_ref()
                    .accept()
                    .map(|(stream, addr)| (TcpStream::new(stream), addr))
            })
    }
}
