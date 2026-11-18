"""Loopback-only HTTP bridge to the internal Docker network (no published Docker ports)."""
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from io import BytesIO
import subprocess


class Bridge(BaseHTTPRequestHandler):
    def forward(self):
        if not self.path.startswith(('/auth/v1/', '/rest/v1/', '/functions/v1/')) or any(
            ord(char) < 32 or char == ' ' for char in self.path
        ):
            self.send_error(404)
            return
        length = int(self.headers.get('Content-Length', 0))
        headers = {key: self.headers[key] for key in
                   ('Authorization', 'apikey', 'Content-Type', 'Accept', 'Prefer', 'Range')
                   if key in self.headers}
        headers.update(Host='localhost', Connection='close')
        headers['Content-Length'] = str(length)
        request = [f'{self.command} {self.path} HTTP/1.0', *(f'{k}: {v}' for k,v in headers.items()), '', '']
        raw = '\r\n'.join(request).encode('latin1') + self.rfile.read(length)
        try:
            proc = subprocess.run(['docker', '-H', 'unix:///var/run/docker.sock', 'exec', '-i',
                                   'supabase_db_sucoot-v58-local', 'bash', '-ec',
                                   'exec 3<>/dev/tcp/supabase_kong_sucoot-v58-local/8000; cat >&3; cat <&3'],
                                  input=raw, capture_output=True, timeout=20)
            class Buffer:
                def makefile(self, *args):
                    return BytesIO(proc.stdout)
            response = http.client.HTTPResponse(Buffer())
            response.begin()
            body = response.read()
            self.send_response(response.status)
            for key in ('Content-Type', 'Content-Range', 'Preference-Applied'):
                if value := response.getheader(key):
                    self.send_header(key, value)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (ValueError, OSError, http.client.HTTPException, subprocess.TimeoutExpired):
            self.send_error(502)

    do_GET = do_POST = do_PATCH = do_PUT = do_DELETE = forward


ThreadingHTTPServer(('127.0.0.1', 54329), Bridge).serve_forever()
