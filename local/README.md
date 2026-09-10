# Local Docker classroom demo

Rehearse without AWS credentials or AWS charges. Requires Docker Engine or Docker Desktop running, Docker Compose v2.20+ (or v5), curl, and either Bash with the standard Unix tools or PowerShell 5.1+. Initial setup downloads images; keep them cached for class.

From the repository root, using Bash on Linux, macOS, Git Bash, or WSL:

```bash
./local/demo.sh setup
./local/demo.sh status
./local/demo.sh demo
./local/demo.sh self-heal
./local/demo.sh failover       # optional stop-and-replace demonstration
./local/demo.sh destroy
```

Or the identical PowerShell version, which is the simplest route on Windows:

```powershell
.\local\demo.ps1 setup
.\local\demo.ps1 status
.\local\demo.ps1 demo
.\local\demo.ps1 self-heal
.\local\demo.ps1 failover      # optional stop-and-replace demonstration
.\local\demo.ps1 destroy
```

Open **http://127.0.0.1:8080** for the application and **http://127.0.0.1:8404** for the live backend health dashboard. Twenty fresh HTTP connections show container hostnames and a summary of unique backends. Request order is not guaranteed.

```text
Browser -> HAProxy :8080 -> app1 (Apache :80)
                        -> app2 (Apache :80)
```

Only HAProxy publishes ports, bound to localhost. The Apache containers are accessible inside the Compose network. Each writes its actual hostname into the page at startup. HAProxy actively checks HTTP health and re-resolves Docker DNS when a container is replaced. The three containers have modest CPU/memory limits. No persistent volumes are created.

`self-heal` asks for confirmation, terminates the Apache process inside app1, and verifies Docker automatically restarts it using `restart: unless-stopped`. It verifies an increased restart count and both healthy backends. This restarts the **same container**: its hostname stays the same.

`failover` asks for confirmation, stops app1, shows requests reaching the surviving backend, explicitly recreates app1, and verifies a new container ID and two healthy backends. A warning that only one backend was observed is expected during the stopped phase. If interrupted, rerun `setup` to restore both backends. Failed setup leaves containers available for inspection; run `destroy` when finished.

Compose is a single-machine rehearsal, not an ECS cluster or an AWS ALB emulator. Unlike ECS Service, Compose does not continuously reconcile a desired replica count or replace manually stopped containers. The automatic process restart and explicit container replacement are separate demonstrations. See [Docker restart policy behavior](https://docs.docker.com/engine/containers/start-containers-automatically/).

Confirmation can be skipped explicitly with `--yes` on `self-heal`, `failover`, or `destroy`. Cleanup removes this Compose project's containers and network, verifies their removal, and leaves shared cached images intact. It never runs Docker system prune or touches AWS. **Any AWS demo deployed separately still needs `./destroy.sh`.**

If ports are occupied, use the same overrides for every command:

```bash
export LOCAL_PORT=8088 LOCAL_STATS_PORT=8408
./local/demo.sh setup
```

```powershell
$env:LOCAL_PORT = '8088'; $env:LOCAL_STATS_PORT = '8408'
.\local\demo.ps1 setup
```

For troubleshooting:

```bash
docker compose -f local/compose.yaml logs --tail 100
docker compose -f local/compose.yaml config --quiet
```

The fixed Compose project name is `aws-class-demo-local`; use one copy at a time per Docker daemon. Run against your local Docker context. Closing the terminal does not stop containers.
