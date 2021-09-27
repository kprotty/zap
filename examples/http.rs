use hyper::{
    server::{conn::Http, Builder},
    service::{make_service_fn, service_fn},
    Body, Request, Response,
};
use std::convert::Infallible;

async fn hello_world(_: Request<Body>) -> Result<Response<Body>, Infallible> {
    Ok(Response::new(Body::from("Hello World")))
}

pub fn main() -> Result<(), hyper::Error> {
    zap::runtime::Builder::new()
        .max_threads(std::num::NonZeroUsize::new(6).unwrap())
        .block_on(async {
            let addr = "127.0.0.1:3000".parse().unwrap();
            let listener = zap::net::TcpListener::bind(addr).expect("failed to bind TcpListener");

            let make_svc =
                make_service_fn(|_conn| async { Ok::<_, Infallible>(service_fn(hello_world)) });

            let server = Builder::new(compat::HyperListener(listener), Http::new())
                .executor(compat::HyperExecutor)
                .serve(make_svc);

            println!("Listening on http://{}", addr);
            server.await?;
            Ok(())
        })
}

mod compat {
    use std::{
        future::Future,
        io,
        pin::Pin,
        task::{Context, Poll},
    };

    #[derive(Clone)]
    pub struct HyperExecutor;

    impl<F> hyper::rt::Executor<F> for HyperExecutor
    where
        F: Future + Send + 'static,
        F::Output: Send + 'static,
    {
        fn execute(&self, fut: F) {
            zap::task::spawn(fut);
        }
    }

    pub struct HyperListener(pub zap::net::TcpListener);

    impl hyper::server::accept::Accept for HyperListener {
        type Conn = HyperStream;
        type Error = io::Error;

        fn poll_accept(
            mut self: Pin<&mut Self>,
            ctx: &mut Context,
        ) -> Poll<Option<Result<Self::Conn, Self::Error>>> {
            match Pin::new(&mut self.0).poll_accept(ctx) {
                Poll::Pending => Poll::Pending,
                Poll::Ready(Err(e)) => Poll::Ready(Some(Err(e))),
                Poll::Ready(Ok((stream, _))) => Poll::Ready(Some(Ok(HyperStream(stream)))),
            }
        }
    }

    use tokio::io::{AsyncRead, AsyncWrite};

    pub struct HyperStream(pub zap::net::TcpStream);

    impl AsyncRead for HyperStream {
        fn poll_read(
            mut self: Pin<&mut Self>,
            ctx: &mut Context,
            buf: &mut tokio::io::ReadBuf<'_>,
        ) -> Poll<io::Result<()>> {
            Pin::new(&mut self.0).poll_read(ctx, buf)
        }
    }

    impl AsyncWrite for HyperStream {
        fn poll_write(
            mut self: Pin<&mut Self>,
            ctx: &mut Context,
            buf: &[u8],
        ) -> Poll<io::Result<usize>> {
            Pin::new(&mut self.0).poll_write(ctx, buf)
        }

        fn poll_flush(mut self: Pin<&mut Self>, ctx: &mut Context) -> Poll<io::Result<()>> {
            Pin::new(&mut self.0).poll_flush(ctx)
        }

        fn poll_shutdown(mut self: Pin<&mut Self>, ctx: &mut Context) -> Poll<io::Result<()>> {
            Pin::new(&mut self.0).poll_shutdown(ctx)
        }
    }
}
