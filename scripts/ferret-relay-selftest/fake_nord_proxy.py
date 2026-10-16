"""A stand-in for a NordVPN HTTPS proxy (without TLS): accepts CONNECT only with the expected
Proxy-Authorization, then tunnels to the requested host."""
import base64, socket, sys, threading

PORT, USER, PASSWORD = int(sys.argv[1]), sys.argv[2], sys.argv[3]
EXPECTED = "Basic " + base64.b64encode(f"{USER}:{PASSWORD}".encode()).decode()


def pipe(src, dst):
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        for s in (src, dst):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


def handle(client):
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = client.recv(4096)
        if not chunk:
            client.close()
            return
        buf += chunk
    header, rest = buf.split(b"\r\n\r\n", 1)
    lines = header.decode().split("\r\n")
    method, target, _ = lines[0].split(" ")
    auth = next((l.split(":", 1)[1].strip() for l in lines[1:] if l.lower().startswith("proxy-authorization:")), "")
    if method != "CONNECT" or auth != EXPECTED:
        client.sendall(b"HTTP/1.1 407 Proxy Authentication Required\r\n\r\n")
        client.close()
        return
    host, port = target.rsplit(":", 1)
    upstream = socket.create_connection((host, int(port)))
    client.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
    if rest:
        upstream.sendall(rest)
    threading.Thread(target=pipe, args=(client, upstream), daemon=True).start()
    pipe(upstream, client)


server = socket.socket()
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", PORT))
server.listen(64)
while True:
    conn, _ = server.accept()
    threading.Thread(target=handle, args=(conn,), daemon=True).start()
