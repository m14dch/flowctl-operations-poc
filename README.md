# Flowctl Operations Portal PoC

A local proof of concept for replacing Jenkins operational jobs with [flowctl](https://github.com/cvhariharan/flowctl) (v0.16.0).
Operators log in, choose **Lookup Service A** or **Lookup Service B**, and enter a `reference`. flowctl then calls
`GET /api/lookup?reference=…` on the matching mock service, using that service's Basic Auth credentials.

```
browser ──► flowctl :7070 ──(script executor + curl, Basic Auth)──► service-a:8080 / service-b:8080
   │            │                                                     (internal network only)
   └──► Dex :5556 (OIDC login)     PostgreSQL (flows, users, executions, secrets)
```

| Component | Purpose |
| --- | --- |
| `flowctl` | Web UI, flow forms, RBAC, execution history. Image = upstream `0.16.0` + `curl` (`flowctl/Dockerfile`) |
| `flowctl-migrate` | One-shot DB install/migration |
| `postgres` | flowctl persistence |
| `dex` | OIDC identity provider for operators (`dex/config.yaml`) |
| `service-a`, `service-b` | FastAPI mock lookup services with Basic Auth (`mock-service/`) |

```
compose.yaml                     # whole stack (based on the upstream flowctl docker-compose.yaml)
.env.example                     # copy to .env; all credentials live there (never committed)
dex/config.yaml                  # Dex OIDC client and demo users
flowctl/Dockerfile               # flowctl 0.16.0 + curl
flows/operations/<flow_id>/      # flow definitions, loaded by flowctl at startup
mock-service/                    # FastAPI mock lookup service (used for both A and B)
specs.md                         # original PoC specification
```

## Start

Prerequisites: Docker with Compose v2.

```sh
cp .env.example .env     # then replace every value (see the comments in the file)
docker compose up -d --build
docker compose ps        # all services should be healthy; flowctl-migrate exits with 0
```

Open http://localhost:7070. flowctl listens on 7000 inside the container, but on the host that port is taken by the macOS
AirPlay Receiver, so it's published on 7070 instead.

## One-time setup (as admin)

flowctl only loads flow files at startup, and only for namespaces that already exist. Secrets can only be added
through the UI. So after the first start:

1. Log in with the **admin** username and password from `.env` (password login).
2. **Create the namespace** `operations`.
3. Run `docker compose restart flowctl`. flowctl then loads `flows/operations/*`, and both flows appear in the `operations` namespace.
4. **Add the secrets** under each flow's *Secrets* tab, using the values from `.env`:
   - Lookup Service A: `SERVICE_A_USER`, `SERVICE_A_PASSWORD`
   - Lookup Service B: `SERVICE_B_USER`, `SERVICE_B_PASSWORD`
5. Have `operator@flowctl.internal` log in once through **Dex**, so that the user gets created. Then, as admin, add
   that user to namespace `operations` with the role **operator** (*Members → Add Member*).

All of this is stored in PostgreSQL and survives restarts.

## Using it

1. Log in through **Dex** (button on the login page) as `operator@flowctl.internal` / `operator-demo`.
2. Switch the namespace (top left) from `default` to **operations**, then open **Flows**.
3. Run **Lookup Service A** or **B** with a reference, e.g. `ABC123`.
4. The results page shows the HTTP status and response body under **Logs**, and `HTTP_STATUS` under **Outputs**.
   **History** lists every run with its user, time and status.

The script a flow runs is shown on the flow's **Versions** page (`/view/operations/flows/<flow_id>/versions`).

## Users and roles

| Login | How | Access |
| --- | --- | --- |
| admin (`.env`) | password login | superuser: manages namespaces, flows, secrets, members |
| `operator@flowctl.internal` / `operator-demo` | Dex | `operator` in `operations`: run both flows, view all executions |
| `noaccess@flowctl.internal` / `noaccess-demo` | Dex | only the empty `default` namespace: can't see or run the flows |

**OIDC is used for authentication only.** flowctl doesn't read groups or roles from the identity provider. All
authorization (namespace roles, groups) is configured in flowctl itself, through the UI or the REST API.

Every OIDC user is created automatically on first login, with the role `user` in the `default` namespace only. Access to
`operations` has to be granted explicitly. The Dex users and passwords are local demo values.

## Security notes

- Operator login (Dex/OIDC, or the admin password) is separate from the downstream technical Basic Auth credentials.
- Downstream credentials are stored as encrypted flowctl flow secrets (`{{ secrets.… }}`), keyed by `KEYSTORE_KEEPER_URL`.
  The flow script reaches them only through environment variables. They're passed to curl through a config on stdin, so
  they never show up in argv or the logs, and the script never prints them.
- The target URLs are hard-coded in the flow files. Operators can only supply `reference`. flowctl validates it on the
  server side against `^[A-Za-z0-9_-]{1,64}$`, and it's URL-encoded with `curl --data-urlencode`. It's never interpolated
  into shell code.
- The mock services publish no ports. flowctl and Dex bind to `127.0.0.1` only.
- No Docker socket is mounted. The upstream compose mounts it for the `docker` executor, but this PoC uses the `script`
  executor instead.
- Images are pinned: flowctl `0.16.0`, postgres `17.0-alpine3.20`, dex `v2.44.0-alpine`, python `3.12.8-slim-bookworm`.
- HTTP is used inside the compose network. Production needs TLS.

## Deviations from `specs.md`

| Spec | PoC | Reason |
| --- | --- | --- |
| Mode A: operator Basic Auth | not available | flowctl allows password login only for the bootstrap admin; all other users must use OIDC |
| Keycloak (Mode B) | Dex | Keeps the PoC simple; Dex is what the upstream compose already uses |
| Map IdP groups to roles | roles assigned in flowctl | flowctl has no OIDC group/claim mapping; roles are set per namespace in the UI |
| Native HTTP executor | `script` executor + curl | flowctl has no HTTP executor (only `docker`, `script`, `flow`) |
| Secrets provisioned automatically | entered once in the UI | flowctl flow secrets can only be added after the flow exists |
| Log redaction | not printing secrets | flowctl has no built-in log masking |
| Layout `flowctl/workflows/*.yaml` | `flows/<namespace>/<flow_id>/<flow_id>.yaml` | Directory layout that flowctl requires |

## Known issues

- **Live logs are missing for very fast runs (flowctl 0.16.0 bug).** `waitForLogger` (`internal/core/logs.go`) polls every 100 ms
  for an *open* execution logger and checks the DB status only once. A run that finishes between two polls is missed, so the
  results page shows "0 lines" until the 30 s stream timeout, or until you refresh. Workaround: the mock services wait
  `RESPONSE_DELAY_SECONDS` (1 s in `compose.yaml`) before responding.

## Acceptance tests

Verified on macOS with Docker 29.9.3, using the flowctl API and the web UI (spec §9; Keycloak not in scope).

| Test | How | Result |
| --- | --- | --- |
| Stack healthy | `docker compose ps` | all healthy, `flowctl-migrate` exits 0 |
| Login page | open http://localhost:7070 | login page with password form and **Dex** button |
| Operator login | **Dex** → `operator@flowctl.internal` / `operator-demo` | logged in; user created on first login |
| Service A / B lookup | run the flow with `ABC123` | `HTTP status: 200`, `"service":"service-a"` / `"service-b"` |
| Empty or invalid reference | run with `` or `x&y=1` | rejected server-side (`VALIDATION_FAILED`), no execution |
| Wrong downstream credentials | set a wrong flow secret, run | `HTTP status: 401`, execution failed; no password or `Authorization` in logs |
| No login | `curl -i http://localhost:7070/api/v1/operations/flows` | `401` |
| No role | log in as `noaccess@…` | `403` on the `operations` namespace and on triggering flows |
| Operator can't manage secrets | add a flow secret as operator | `403` |
| History | **History** page | flow, user, input, time and status recorded |
| Persistence | `docker compose down` + `up` (without `-v`) | flows, secrets, members, history and logs kept; users log in again |

Testing a mock service directly (from inside the network):

```sh
docker compose exec flowctl curl -s -u "service-a-user:<password>" "http://service-a:8080/api/lookup?reference=ABC123"
docker compose exec flowctl curl -si "http://service-a:8080/api/lookup?reference=ABC123"   # 401 + WWW-Authenticate
```

## Reset

```sh
docker compose down -v   # removes the database and log volumes
```

## License

[Apache License 2.0](LICENSE). flowctl itself is a separate project, also licensed under Apache 2.0.
