"""Local TCP/UDP destinations reached only through the acceptance Xray server."""
import socket
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


threading.Thread(target=serve_tcp, daemon=True).start()
threading.Thread(target=serve_udp, daemon=True).start()
while True:
    time.sleep(1)
