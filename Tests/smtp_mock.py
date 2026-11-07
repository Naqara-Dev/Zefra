#!/usr/bin/env python3
"""A tiny SMTP server for the end-to-end test: speaks STARTTLS and AUTH, and writes what it got to a file.
smtp_mock.py <port> <cert> <key> <out> [--no-starttls]"""
import base64, socket, ssl, sys

port, cert, key, out = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
offers_tls = "--no-starttls" not in sys.argv
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(cert, key)
server = socket.socket()
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", port))
server.listen(1)
# Never hold a test up: nothing arriving in 40 s means it failed.
server.settimeout(40)
print("ready", flush=True)
client, _ = server.accept()
client.settimeout(40)
stream = client.makefile("rb")
encrypted = False
def send(line):
    client.sendall((line + "\r\n").encode())
send("220 mock ESMTP")
log = []
while True:
    raw = stream.readline()
    if not raw:
        break
    line = raw.decode("utf-8", "replace").strip()
    verb = line.split(" ")[0].upper()
    if verb in ("EHLO", "HELO"):
        lines = ["250-mock"]
        if offers_tls and not encrypted:
            lines.append("250-STARTTLS")
        if encrypted:
            lines.append("250-AUTH PLAIN LOGIN")
        lines.append("250 8BITMIME")
        client.sendall(("\r\n".join(lines) + "\r\n").encode())
    elif verb == "STARTTLS":
        send("220 go")
        client = context.wrap_socket(client, server_side=True)
        stream = client.makefile("rb")
        encrypted = True
    elif verb == "AUTH":
        parts = line.split(" ")
        if parts[1].upper() == "PLAIN":
            blob = parts[2] if len(parts) > 2 else None
            if blob is None:
                send("334 ")
                blob = stream.readline().decode().strip()
            log.append("AUTH " + base64.b64decode(blob).decode("utf-8", "replace").replace("\0", "|"))
            send("235 ok")
        else:
            send("504 no")
    elif verb == "MAIL":
        log.append("ENCRYPTED " + str(encrypted))
        log.append(line)
        send("250 ok")
    elif verb == "RCPT":
        log.append(line)
        send("250 ok")
    elif verb == "DATA":
        send("354 go")
        body = []
        while True:
            row = stream.readline().decode("utf-8", "replace")
            if row in (".\r\n", ".\n", ""):
                break
            body.append(row)
        log.append("BODY\n" + "".join(body))
        send("250 queued")
    elif verb == "QUIT":
        send("221 bye")
        break
    else:
        send("500 what")
open(out, "w").write("\n".join(log))
