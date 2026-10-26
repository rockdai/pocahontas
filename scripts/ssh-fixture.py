#!/usr/bin/env python3
"""Loopback-only SSH echo fixture. Never executes a command or opens a shell."""
import argparse
import base64
import pathlib
import socket
import threading
import time
import paramiko

parser = argparse.ArgumentParser()
parser.add_argument('--port', type=int, default=62223)
parser.add_argument('--state-dir', type=pathlib.Path, required=True)
args = parser.parse_args()
args.state_dir.mkdir(parents=True, exist_ok=True)
host_key_path = args.state_dir / 'test-host-key'
if not host_key_path.exists():
    paramiko.ECDSAKey.generate().write_private_key_file(str(host_key_path))
    host_key_path.chmod(0o600)
host_key = paramiko.ECDSAKey.from_private_key_file(str(host_key_path))
root = pathlib.Path(__file__).resolve().parents[1]
public_key = (root / 'Packages/PocahontasKit/Tests/PocahontasKitTests/Fixtures/ed25519_encrypted.pub').read_text().split()[1]
allowed_key = base64.b64decode(public_key)


class Server(paramiko.ServerInterface):
    def __init__(self):
        self.shell = threading.Event()
        self.channel = None

    def get_allowed_auths(self, username):
        return 'password,publickey'

    def check_auth_password(self, username, password):
        return paramiko.AUTH_SUCCESSFUL if (username, password) == ('fixture', 'pocahontas-test') else paramiko.AUTH_FAILED

    def check_auth_publickey(self, username, key):
        return paramiko.AUTH_SUCCESSFUL if username == 'fixture' and key.asbytes() == allowed_key else paramiko.AUTH_FAILED

    def check_channel_request(self, kind, chanid):
        return paramiko.OPEN_SUCCEEDED if kind == 'session' else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED

    def check_channel_pty_request(self, channel, term, width, height, pixelwidth, pixelheight, modes):
        self.channel = channel
        return True

    def check_channel_shell_request(self, channel):
        self.shell.set()
        return True

    def check_channel_window_change_request(self, channel, width, height, pixelwidth, pixelheight):
        if self.shell.is_set():
            channel.sendall(f'\r\nRESIZE:{width}x{height}\r\n'.encode())
        return True


def handle(client):
    transport = paramiko.Transport(client)
    transport.add_server_key(host_key)
    server = Server()
    try:
        transport.start_server(server=server)
        channel = transport.accept(15)
        if channel is None or not server.shell.wait(15):
            return
        time.sleep(0.05)
        channel.sendall(b'\x1b[2J\x1b[H\x1b[32mpocahontas SSH fixture\x1b[0m\r\n')
        channel.sendall('Connected through SSH. 中文输入 / resize / binary echo\r\n$ '.encode())
        while transport.is_active():
            data = channel.recv(32768)
            if not data:
                break
            channel.sendall(data)
    except (EOFError, OSError, paramiko.SSHException):
        pass
    finally:
        transport.close()


with socket.socket() as listener:
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(('127.0.0.1', args.port))
    listener.listen(10)
    print(f'Fixture listening on 127.0.0.1:{args.port}', flush=True)
    while True:
        client, _ = listener.accept()
        threading.Thread(target=handle, args=(client,), daemon=True).start()
