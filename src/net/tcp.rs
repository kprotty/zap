use super::super::runtime::io::{IoFairness, IoKind, IoSource};
use std::{
    cell::RefCell,
    future::Future,
    io::{self, Read, Write},
    mem::MaybeUninit,
    net::SocketAddr,
    pin::Pin,
    task::{Context, Poll, Waker},
};

pub struct TcpStream {
    source: IoSource<mio::net::TcpStream>,
    reader: RefCell<IoFairness>,
    writer: RefCell<IoFairness>,
}

impl TcpStream {
    fn new(stream: mio::net::TcpStream) -> Self {
        Self {
            source: IoSource::new(stream),
            reader: RefCell::new(IoFairness::default()),
            writer: RefCell::new(IoFairness::default()),
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
}

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
            self.writer
                .borrow_mut()
                .poll_io(&self.source, IoKind::Write, ctx.waker(), || {
                    self.source.as_ref().write(buf)
                })
        }
    }

    fn poll_write_vectored(
        self: Pin<&mut Self>,
        ctx: &mut Context<'_>,
        bufs: &[io::IoSlice<'_>],
    ) -> Poll<io::Result<usize>> {
        unsafe {
            self.writer
                .borrow_mut()
                .poll_io(&self.source, IoKind::Write, ctx.waker(), || {
                    self.source.as_ref().write_vectored(bufs)
                })
        }
    }

    fn is_write_vectored(&self) -> bool {
        true
    }

    #[inline]
    fn poll_flush(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<io::Result<()>> {
        self.source.as_ref().flush()?;
        Poll::Ready(Ok(()))
    }

    fn poll_shutdown(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<io::Result<()>> {
        self.source.as_ref().shutdown(std::net::Shutdown::Write)?;
        Poll::Ready(Ok(()))
    }
}

pub struct TcpListener {
    source: IoSource<mio::net::TcpListener>,
    fairness: RefCell<IoFairness>,
}

impl TcpListener {
    pub fn bind(addr: SocketAddr) -> io::Result<Self> {
        let source = mio::net::TcpListener::bind(addr)?;
        Ok(Self {
            source: IoSource::new(source),
            fairness: RefCell::new(IoFairness::default()),
        })
    }

    pub fn accept<'a>(&'a self) -> impl Future<Output = io::Result<(TcpStream, SocketAddr)>> + 'a {
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
