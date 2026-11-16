# A local stand-in for a video site, for Downstream's checks: python3 server.py <media file> [port]
# Prints "PORT <n>" once listening. Paths:
#   /v/<name>.mp4            the media file (Range supported)
#   /slow/<name>.mp4         the same, at ~150 kB/s
#   /crawl/<name>.mp4        the same, at ~30 kB/s
#   /busy/<n>/<name>.mp4     answers 429 to the first <n> downloads, then serves
#   /stall/<name>.mp4        the first download sends a little and then hangs; later ones serve
#                            (the second GET: yt-dlp's first one only looks at what the link is)
#   /missing/<name>.mp4      404, until /heal has been requested
#   /heal                    makes /missing serve from now on
#   /feed.xml                an RSS feed (a playlist to yt-dlp): /v/a.mp4, /missing/b.mp4, /v/c.mp4
# "Downloads" are GET requests: yt-dlp looks at a link with HEAD first, which always succeeds here.
import sys, time, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

media = open(sys.argv[1], 'rb').read()
seen = {}
healed = False
lock = threading.Lock()

class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *args): pass

    def count(self, key):
        with lock:
            seen[key] = seen.get(key, 0) + 1
            return seen[key]

    def do_HEAD(self): self.respond(body=False)
    def do_GET(self): self.respond(body=True)

    def plain(self, status, text=b''):
        self.send_response(status)
        self.send_header('Content-Length', str(len(text)))
        self.end_headers()
        self.wfile.write(text)

    def respond(self, body):
        parts = self.path.strip('/').split('/')
        kind = parts[0]
        if kind == 'feed.xml':
            host = self.headers['Host']
            items = ''.join(f'<item><title>{n}</title><enclosure url="http://{host}/{p}/{n}.mp4" type="video/mp4"/></item>'
                            for p, n in (('v', 'a'), ('missing', 'b'), ('v', 'c')))
            text = f'<?xml version="1.0"?><rss version="2.0"><channel><title>feed</title>{items}</channel></rss>'.encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/rss+xml')
            self.send_header('Content-Length', str(len(text)))
            self.end_headers()
            if body: self.wfile.write(text)
            return
        global healed
        if kind == 'heal':
            healed = True
            return self.plain(200)
        if kind == 'missing' and not healed: return self.plain(404)
        if kind == 'busy' and body and self.count(self.path) <= int(parts[1]): return self.plain(429)
        start, end = 0, len(media) - 1
        rng = self.headers.get('Range')
        if rng and rng.startswith('bytes='):
            a, _, b = rng[6:].partition('-')
            start = int(a or 0)
            if b: end = min(end, int(b))
        data = media[start:end + 1]
        self.send_response(206 if rng else 200)
        self.send_header('Content-Type', 'video/mp4')
        self.send_header('Accept-Ranges', 'bytes')
        self.send_header('Content-Length', str(len(data)))
        if rng: self.send_header('Content-Range', f'bytes {start}-{end}/{len(media)}')
        self.end_headers()
        if not body: return
        try:
            if kind == 'stall' and self.count(self.path) == 2:
                self.wfile.write(data[:65536]); self.wfile.flush()
                time.sleep(3600)
            elif kind in ('slow', 'crawl'):
                step = 15000 if kind == 'slow' else 3000
                for i in range(0, len(data), step):
                    self.wfile.write(data[i:i + step]); self.wfile.flush()
                    time.sleep(0.1)
            else:
                self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass

server = ThreadingHTTPServer(('127.0.0.1', int(sys.argv[2]) if len(sys.argv) > 2 else 0), Handler)
server.daemon_threads = True
print('PORT', server.server_address[1], flush=True)
server.serve_forever()
