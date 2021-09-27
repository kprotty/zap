use super::super::runtime::io::{IoKind, IoReadiness, IoSource};
use std::{
    cell::RefCell,
    io::{self, Read, Write},
    mem::MaybeUninit,
    net::SocketAddr,
    pin::Pin,
    task::{Context, Poll},
};

pub struct TcpStream {
    source: IoSource<mio::net::TcpStream>,
    reader: RefCell<IoReadiness>,
    writer: RefCell<IoReadiness>,
}

impl TcpStream {
    pub async fn connect(addr: SocketAddr) -> io::Result<Self> {
        let stream = mio::net::TcpStream::connect(addr)?;
        let this = Self {
            source: IoSource::new(stream),
            reader: RefCell::new(IoReadiness::default()),
            writer: RefCell::new(IoReadiness::default()),
        };

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
        let polled =
            self.reader
                .borrow_mut()
                .poll(&self.source, IoKind::Read, ctx.waker(), || unsafe {
                    let buf = &mut *(buf.unfilled_mut() as *mut [MaybeUninit<u8>] as *mut [u8]);
                    self.source.as_ref().read(buf)
                });

        match polled {
            Poll::Ready(Err(e)) => Poll::Ready(Err(e)),
            Poll::Pending => Poll::Pending,
            Poll::Ready(Ok(n)) => unsafe {
                buf.assume_init(n);
                buf.advance(n);
                Poll::Ready(Ok(()))
            },
        }
    }
}

impl tokio::io::AsyncWrite for TcpStream {
    fn poll_write(
        self: Pin<&mut Self>,
        ctx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        self.writer
            .borrow_mut()
            .poll(&self.source, IoKind::Write, ctx.waker(), || {
                self.source.as_ref().write(buf)
            })
    }

    fn poll_write_vectored(
        self: Pin<&mut Self>,
        ctx: &mut Context<'_>,
        bufs: &[io::IoSlice<'_>],
    ) -> Poll<io::Result<usize>> {
        self.writer
            .borrow_mut()
            .poll(&self.source, IoKind::Write, ctx.waker(), || {
                self.source.as_ref().write_vectored(bufs)
            })
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
}

impl TcpListener {
    pub fn bind(addr: SocketAddr) -> io::Result<Self> {
        let source = mio::net::TcpListener::bind(addr)?;
        Ok(Self {
            source: IoSource::new(source),
        })
    }

    pub async fn accept(&self) -> io::Result<(TcpStream, SocketAddr)> {
        loop {
            unsafe {
                self.source.wait_for(IoKind::Read).await;
            }

            match self.try_accept() {
                Poll::Pending => continue,
                Poll::Ready(result) => return result,
            }
        }
    }

    pub fn poll_accept(
        self: Pin<&mut Self>,
        ctx: &mut Context<'_>,
    ) -> Poll<io::Result<(TcpStream, SocketAddr)>> {
        loop {
            match unsafe { self.source.poll_update(IoKind::Read, Some(ctx.waker())) } {
                Poll::Ready(_) => {}
                Poll::Pending => return Poll::Pending,
            }

            match self.try_accept() {
                Poll::Pending => continue,
                Poll::Ready(result) => return Poll::Ready(result),
            }
        }
    }

    fn try_accept(&self) -> Poll<io::Result<(TcpStream, SocketAddr)>> {
        loop {
            match self.source.as_ref().accept() {
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => return Poll::Pending,
                Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                Err(e) => return Poll::Ready(Err(e)),
                Ok((stream, addr)) => {
                    let stream = TcpStream {
                        source: IoSource::new(stream),
                        reader: RefCell::new(IoReadiness::default()),
                        writer: RefCell::new(IoReadiness::default()),
                    };
                    return Poll::Ready(Ok((stream, addr)));
                }
            }
        }
    }
}
