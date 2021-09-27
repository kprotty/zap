use hyper::{
    service::{make_service_fn, service_fn},
    Body, Request, Response, Server,
};
use std::convert::Infallible;

async fn hello_world(_: Request<Body>) -> Result<Response<Body>, Infallible> {
    Ok(Response::new(Body::from("Hello World")))
}

pub fn main() -> Result<(), hyper::Error> {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(6)
        .enable_io()
        .build()
        .unwrap()
        .block_on(async move {
            let make_svc =
                make_service_fn(|_conn| async { Ok::<_, Infallible>(service_fn(hello_world)) });

            let addr = ([127, 0, 0, 1], 3000).into();
            let server = Server::bind(&addr).serve(make_svc);

            println!("Listening on http://{}", addr);
            server.await?;
            Ok(())
        })
}
