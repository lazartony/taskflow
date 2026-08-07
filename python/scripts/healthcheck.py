"""Container HEALTHCHECK for the distroless image.

Distroless has no shell, no curl and no wget — but it does have the Python
runtime, so the check is stdlib-only Python with zero third-party imports (it
must keep working even if the venv is not on the path).

Probes LIVE, not READY — see app/routers/health.py for why that distinction
matters (OBS5.1).
"""

import os
import sys
import urllib.request

port = os.environ.get("PORT") or "8080"
url = f"http://127.0.0.1:{port}/api/v1/health/live"

# The URL is built from a fixed loopback host and a numeric port, so there is no
# scheme- or host-injection surface here for ruff's S310 to warn about.
try:
    with urllib.request.urlopen(url, timeout=2) as response:
        sys.exit(0 if response.status == 200 else 1)
except Exception:
    sys.exit(1)
