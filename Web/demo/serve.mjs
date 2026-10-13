// Serves Web/ on localhost for the demo page. No dependencies.
import { createReadStream, statSync } from 'node:fs';
import { createServer } from 'node:http';
import { extname, join, normalize, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const types = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.map': 'application/json',
  '.wasm': 'application/wasm',
};
const port = Number(process.env.PORT ?? 8000);

createServer((request, response) => {
  let path = normalize(join(root, decodeURIComponent(new URL(request.url, 'http://localhost').pathname)));
  try {
    if (!path.startsWith(root)) throw new Error('outside the root');
    if (statSync(path).isDirectory()) path = join(path, 'index.html');
    statSync(path);
  } catch {
    response.writeHead(404).end('not found');
    return;
  }
  response.writeHead(200, {
    'content-type': types[extname(path)] ?? 'application/octet-stream',
    'cache-control': 'no-store',
  });
  createReadStream(path).pipe(response);
}).listen(port, '127.0.0.1', () => {
  console.log(`http://localhost:${port}/demo/`);
});
