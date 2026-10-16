"""Local TCP/UDP destinations reached only through the acceptance Xray server."""
import socket
import ssl
import os
import threading
import time


def serve_tcp():
    with socket.socket() as server:
        server.bind(("127.0.0.1", 15555))
        server.listen()
        while True:
            connection, _ = server.accept()
            with connection:
                connection.sendall(b"private-network-tun-tcp\n")


def serve_udp():
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as server:
        server.bind(("127.0.0.1", 15555))
        while True:
            payload, address = server.recvfrom(2048)
            server.sendto(b"private-network-tun-udp:" + payload, address)


def serve_tls():
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_3
    context.maximum_version = ssl.TLSVersion.TLSv1_3
    context.set_alpn_protocols(["h2", "http/1.1"])
    context.load_cert_chain(os.environ["TUN_FIXTURE_CERT"], os.environ["TUN_FIXTURE_KEY"])

    def handshake(connection):
        try:
            connection.settimeout(3)
            with context.wrap_socket(connection, server_side=True) as secure:
                secure.recv(1024)
        except (OSError, ssl.SSLError):
            connection.close()

    with socket.socket() as server:
        server.bind(("127.0.0.1", 15444))
        server.listen()
        while True:
            connection, _ = server.accept()
            # REALITY probes may leave the target handshake unfinished.
            threading.Thread(target=handshake, args=(connection,), daemon=True).start()


threading.Thread(target=serve_tcp, daemon=True).start()
threading.Thread(target=serve_udp, daemon=True).start()
if "TUN_FIXTURE_CERT" in os.environ:
    threading.Thread(target=serve_tls, daemon=True).start()
while True:
    time.sleep(1)
