"""Run the repository's admin-accounts function behind the isolated local Kong."""
import base64
import hashlib
import hmac
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
NETWORK = "sucoot-v58-local"
NAME = "supabase_edge_runtime_" + NETWORK
IMAGE = "ghcr.io/supabase/edge-runtime@sha256:987dacbf3e50384cb5c6bb14bc5f6d4e7afb138d01fe0e6edd19d1767d7eebe5"
DOCKER = ["docker", "-H", "unix:///var/run/docker.sock"]


def inspect(*args):
    return subprocess.check_output(DOCKER + list(args), text=True).strip()


def encoded(obj):
    return base64.urlsafe_b64encode(json.dumps(obj).encode()).rstrip(b"=")


def local_key(role, secret):
    payload = encoded({"alg": "HS256", "typ": "JWT"}) + b"." + encoded({"role": role})
    signature = base64.urlsafe_b64encode(hmac.digest(secret, payload, "sha256")).rstrip(b"=")
    return (payload + b"." + signature).decode()


if inspect("network", "inspect", "-f", "{{.Internal}}", NETWORK) != "true":
    raise SystemExit("Local network must be internal")
auth = "supabase_auth_" + NETWORK
if list(json.loads(inspect("inspect", "-f", "{{json .NetworkSettings.Networks}}", auth))) != [NETWORK]:
    raise SystemExit("Unexpected Auth network")
source = (ROOT / "supabase/functions/admin-accounts/index.ts").read_text()
# Resolve the function's pinned npm dependency from the checked-in frontend lockfile.
version = json.loads((ROOT / "node_modules/@supabase/supabase-js/package.json").read_text())["version"]
specifier = "npm:@supabase/supabase-js@" + version
if specifier + '"' not in source:
    raise SystemExit("Local supabase-js version differs from Edge Function import")
with tempfile.TemporaryDirectory() as tmp:
    entry = Path(tmp) / "index.ts"
    subprocess.run([ROOT / "node_modules/.bin/esbuild", "--loader=ts", "--format=esm",
                    "--platform=browser", "--bundle", "--outfile=" + str(entry)],
                   input=source.replace(specifier, "@supabase/supabase-js"), text=True, cwd=ROOT, check=True)
    digest = hashlib.sha256(entry.read_bytes()).hexdigest()
    existing = subprocess.run(DOCKER + ["inspect", NAME], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    if existing.returncode == 0:
        config = json.loads(existing.stdout)[0]
        if (list(config["NetworkSettings"]["Networks"]) != [NETWORK] or config["HostConfig"]["PortBindings"]
                or config["Config"]["Labels"].get("sucoot.edge.bundle") != digest):
            raise SystemExit("Unexpected local Edge container configuration")
        subprocess.run(DOCKER + ["start", NAME], check=True)
    else:
        secret = inspect("exec", auth, "printenv", "GOTRUE_JWT_SECRET").encode()
        env = dict(os.environ, SUPABASE_URL="http://supabase_kong_" + NETWORK + ":8000",
                   SUPABASE_SERVICE_ROLE_KEY=local_key("service_role", secret), SUPABASE_ANON_KEY=local_key("anon", secret))
        subprocess.run(DOCKER + ["create", "--name", NAME, "-e", "NO_PROXY=*", "-e", "no_proxy=*", "-e", "HTTP_PROXY=", "-e", "HTTPS_PROXY=", "-e", "http_proxy=", "-e", "https_proxy=", "--network", NETWORK, "--label",
                       "sucoot.edge.bundle=" + digest, "-e", "SUPABASE_URL", "-e", "SUPABASE_SERVICE_ROLE_KEY",
                       "-e", "SUPABASE_ANON_KEY", IMAGE, "start", "--port", "8081", "--main-service", "/function"],
                       env=env, check=True)
        subprocess.run(DOCKER + ["cp", tmp + "/.", NAME + ":/function"], check=True)
        subprocess.run(DOCKER + ["start", NAME], check=True)
