use "net"
use "valbytes"

actor Main
  new create(env: Env) =>
    try 
      let port = "9000"
      let listener = TCPListener(
        env.root as AmbientAuth,
        recover HttpListener end,
        "127.0.0.1",
        port
      )
      env.err.print("Listening on :" + port)
    end

class HttpListener is TCPListenNotify
  fun ref connected(listen: TCPListener ref): TCPConnectionNotify iso^ =>
    HttpConnection
  
  fun ref not_listening(liste: TCPListener ref) =>
    None

class HttpConnection is TCPConnectionNotify
  var buffer: ByteArrays = ByteArrays()

  fun ref accepted(conn: TCPConnection ref) =>
    None

  fun ref connect_failed(conn: TCPConnection ref) =>
    None

  fun ref received(conn: TCPConnection ref, data: Array[U8] iso, times: USize): Bool =>
    buffer = buffer + consume data
    while true do
      match buffer.find("\r\n\r\n")
      | (true, let request_end: USize) =>
        conn.write("HTTP/1.1 200 Ok\r\nContent-Length: 10\r\nContent-Type: text/plain; charset=utf8\r\nDate: Thu, 19 Nov 2020 14:26:34 GMT\r\nServer: fasthttp\r\n\r\nHelloWorld")
        buffer = buffer.drop(request_end + 4)
      else
        break
      end
    end
    true
