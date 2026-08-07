/**
 * Container HEALTHCHECK for the distroless image.
 *
 * Distroless has no shell, no curl and no wget — but it does have the Node
 * runtime, so the check is plain Node with zero dependencies.
 *
 * Deliberately CommonJS (`.cjs`) even though the package is `"type": "module"`.
 * The Dockerfile also installs this file as `/healthcheck` with a
 * `#!/nodejs/bin/node` shebang so that compose's shared
 * `test: ["CMD", "/healthcheck"]` anchor works for this service too — and a
 * file with no extension is parsed as CommonJS, so the same source has to work
 * both ways.
 *
 * Probes LIVE, not READY — see src/routes/health.ts for why that distinction
 * matters (OBS5.1).
 */
'use strict';

const { get } = require('node:http');

const port = process.env.PORT || '8080';

const req = get(
  { host: '127.0.0.1', port: port, path: '/api/v1/health/live', timeout: 2000 },
  (res) => {
    res.resume(); // drain so the socket can close
    process.exit(res.statusCode === 200 ? 0 : 1);
  },
);

req.on('timeout', () => {
  req.destroy();
  process.exit(1);
});
req.on('error', () => process.exit(1));
