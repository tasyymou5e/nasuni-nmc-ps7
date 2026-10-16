# Running in Docker (Docker Desktop or any Docker host)

One image, built from `docker/Dockerfile`, runs on PowerShell 7.4 LTS on Azure Linux 3.0. The base is Microsoft's official image, published for both **amd64 and arm64**, so it runs natively on Apple Silicon and x86.

| Target | Contains | Use |
|---|---|---|
| `runtime` | Modules, dashboard, MCP server, Pode 2.14.1 | Production dashboard or MCP server |
| `demo` | `runtime` + fake NMC with sample data | Local demo on a laptop (development mode only) |
| `test` | `runtime` + Pester + PSScriptAnalyzer + the full repo | Runs every build gate on Linux during `docker build` |

## Demo (Docker Desktop)

```bash
docker compose up --build demo
```

Then open http://localhost:8765 and sign in as `viewer`, `op` or `admin`.

- **Port:** the port is published to `127.0.0.1` only. The demo uses a development sign-in and plain HTTP, so it must never be reachable from the network.
- **Hardening:** the container runs as uid 10001 with a read-only root filesystem, no capabilities and `no-new-privileges`.
- **Data:** the fake NMC and all demo data live in the container's temporary storage and reset on restart.

To move the demo to another machine:

```bash
docker save nasuni-nmc:demo | gzip > nasuni-nmc-demo.tar.gz
docker load < nasuni-nmc-demo.tar.gz      # on the other machine, then:
docker run --rm -p 127.0.0.1:8765:8765 --read-only --tmpfs /tmp --tmpfs /home/nasuni:uid=10001,gid=10001 nasuni-nmc:demo
```

Alternatively, push the image to your registry.

## Production dashboard

1. Put these in `deploy/config/` (mounted read-only at `/etc/nasuni`; never committed, and excluded by `.dockerignore`):
   - `dashboard-config.psd1`, based on `src/Nasuni.Nmc.Dashboard/dashboard-config.example.psd1`, with:
     - `Address = '0.0.0.0'`
     - `AuditLogPath = '/var/lib/nasuni/audit.jsonl'`
     - `ReportDirectory = '/var/lib/nasuni/reports'`
     - all `*Path` entries pointing under `/etc/nasuni/`
   - The Vault CA certificate, plus the Vault client certificate and key (key `chmod 600`, readable by uid 10001), or the AppRole secret-id file.
2. Start it:

   ```bash
   docker compose --profile prod up -d dashboard
   ```

**FIPS:** a container uses the host's kernel. On a **FIPS-mode Linux host** (`fips=1`), Azure Linux's OpenSSL runs its FIPS provider and the startup check passes. On Docker Desktop, Windows/WSL or a non-FIPS host, the production image refuses to start, by design. Check with:

```bash
docker run --rm nasuni-nmc:runtime diag
```

## MCP server in a container (Claude Desktop / Claude Code)

```json
{ "mcpServers": { "nasuni-nmc": {
    "command": "docker",
    "args": ["run", "-i", "--rm", "--read-only", "--tmpfs", "/tmp", "--tmpfs", "/home/nasuni:uid=10001,gid=10001",
             "-v", "/etc/nasuni:/etc/nasuni:ro", "nasuni-nmc:runtime", "mcp"] } } }
```

`-i` is required, because MCP talks over stdin and stdout.

## Run the test gates on Linux

```bash
docker compose --profile test build tests
```

The build fails if any parse, lint, test or coverage gate fails.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `Cannot connect to the Docker daemon` | Docker Desktop is not running. Start it and wait for "Engine running" |
| Demo exits: `Auth.Mode=DevLogin is only allowed in development mode on a loopback address` | The container exception needs `NASUNI_CONTAINER=1` (set by the image), `Address = '0.0.0.0'` and `Dev.PublishedToHostLoopbackOnly = $true` (set by the demo). It is only reachable through the compose port mapping `127.0.0.1:8765:8765` |
| Production container exits: `host is not in FIPS-approved mode` | Expected on non-FIPS hosts. Run on a FIPS-mode Linux host |
| Dashboard data errors / circuit breaker open | See `docs/TROUBLESHOOTING.md` ("Demo"). `docker compose logs demo` shows the JSON logs, and `docker compose exec demo pwsh` gives a shell |
| Permission denied on `/var/lib/nasuni` | The volume must be writable by uid 10001 |
