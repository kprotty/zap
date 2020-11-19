package main
 
import (
    "log"
    "github.com/valyala/fasthttp"
)
 
func main() {
    err := fasthttp.ListenAndServe("127.0.0.1:9000", handler); if err != nil {
        log.Fatalf("Error in ListenAndServe: %s", err)
    }
}
 
func handler(ctx *fasthttp.RequestCtx) {
    ctx.WriteString("HelloWorld")
}