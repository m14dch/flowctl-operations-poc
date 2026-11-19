# Specification: Flowctl Operations Portal PoC

**Type:** Proof of concept · **Deployment:** Docker Compose

> This is the original specification. For what was actually built, the deviations from this spec and the
> verified test results, see [README.md](README.md).

## 1. Objective

Build a locally runnable proof of concept using [flowctl](https://github.com/cvhariharan/flowctl) as a replacement for Jenkins-based operational actions.

Operators should authenticate, select one of two predefined operations, enter a query parameter, execute a GET request against the corresponding downstream service, and inspect the result.

Flowctl already advertises OIDC, namespace-based RBAC, YAML-defined workflows, secrets, and execution logs under its Apache 2.0 license.

## 2. Architecture

```
Operator browser
      │
      ▼
Flowctl ─────────────────────────────► Keycloak (optional OIDC)
Web UI · Workflow forms · RBAC · Execution history
      │
      ├──► Service A   GET /api/lookup?reference=...   (HTTP Basic Auth)
      ├──► Service B   GET /api/lookup?reference=...   (HTTP Basic Auth)
      │
      ▼
PostgreSQL — Flowctl persistence
```

The two authentication concerns must remain separate: operators authenticate to Flowctl, while Flowctl uses technical Basic Auth credentials for downstream requests.

## 3. Functional requirements

| ID    | Requirement                                                       |
| ----- | ----------------------------------------------------------------- |
| FR-01 | Display two operations: Lookup Service A and Lookup Service B     |
| FR-02 | Each operation accepts one required string parameter, `reference` |
| FR-03 | Call `GET /api/lookup?reference={value}` on the selected service  |
| FR-04 | Authenticate downstream requests using HTTP Basic Auth            |
| FR-05 | Display HTTP status and response body                             |
| FR-06 | Record operator, workflow, input, execution time and result       |
| FR-07 | Prevent operators from specifying arbitrary target URLs           |
| FR-08 | Require operator authentication                                   |
| FR-09 | Restrict workflow execution according to assigned roles           |
| FR-10 | Run locally with Docker Compose                                   |

## 4. Operator authentication

Implement two selectable modes, with Keycloak as the preferred production-like configuration.

- **Mode A — Basic Auth:** Simplest initial setup, provided Flowctl supports local password authentication in the selected release. This must be verified rather than assumed.
- **Mode B — Keycloak OIDC:** Use the Authorization Code flow, ideally with PKCE. Map Keycloak users or groups to Flowctl users and roles.

For the PoC, define an `operator` role that can execute both workflows and an `admin` role that can also manage workflow definitions and access policies.

## 5. Docker Compose deployment

Use the project's official [Docker Compose configuration](https://github.com/cvhariharan/flowctl/blob/master/docker-compose.yaml) as the baseline, rather than rebuilding Flowctl configuration from scratch.

The upstream Compose file already defines PostgreSQL, Flowctl database migrations, Flowctl itself, and Dex as a sample OIDC identity provider. It also exposes a bootstrap administrator username and password.

For the PoC, extend that configuration with two mock downstream services and optionally replace Dex with Keycloak.

Proposed project structure:

```
flowctl-operations-poc/
├── compose.yaml
├── compose.keycloak.yaml
├── .env.example
├── README.md
├── flowctl/
│   └── workflows/
│       ├── lookup-service-a.yaml
│       └── lookup-service-b.yaml
├── mock-service/
│   ├── Dockerfile
│   ├── requirements.txt
│   └── app.py
└── keycloak/
    └── realm.json
```

The base deployment should start with `docker compose up -d`, with Keycloak enabled through a Compose override or profile.

## 6. Downstream mock services

Both services use the same implementation but have different credentials and service identities.

| Property           | Service A        | Service B        |
| ------------------ | ---------------- | ---------------- |
| Container hostname | `service-a`      | `service-b`      |
| Port               | 8080             | 8080             |
| Endpoint           | `/api/lookup`    | `/api/lookup`    |
| Query parameter    | `reference`      | `reference`      |
| Authentication     | Basic Auth       | Basic Auth       |
| Username           | `service-a-user` | `service-b-user` |
| Password           | Separate secret  | Separate secret  |

Example request:

```http
GET /api/lookup?reference=ABC123
Authorization: Basic <base64-credentials>
```

Example response:

```json
{
  "service": "service-a",
  "reference": "ABC123",
  "status": "FOUND",
  "description": "Mock lookup completed"
}
```

Implement both services using a small Python HTTP application, preferably FastAPI. Each service must return `401` with a `WWW-Authenticate` header for invalid credentials and `400` for missing or invalid input.

Neither mock service should need a database. The response can be deterministic.

## 7. Flowctl workflows

Create two independent workflows with the same input contract.

The following shows the intended workflow structure, based on Flowctl's documented YAML format. The HTTP executor configuration and secret references still need to be verified against the selected release.

```yaml
metadata:
  id: lookup_service_a
  name: Lookup Service A
  description: Query downstream service A

inputs:
  - name: reference
    type: string
    label: Reference
    required: true

actions:
  - id: lookup
    name: Execute lookup
    # Use the supported HTTP execution mechanism.
    # GET http://service-a:8080/api/lookup
    # Query parameter: reference
    # Authentication: Basic Auth from secrets
```

For Service B, use the same structure with a separate workflow ID, URL, and credentials.

The implementation must use a supported Flowctl executor. If there is no native HTTP executor, a command-based HTTP client can be used, but it must not interpolate untrusted input into shell commands. Pass validated input through environment variables or structured arguments and use proper URL encoding.

The upstream example documents a Docker executor. However, the official Compose configuration mounts the Docker socket, which introduces a significant security concern. This needs explicit evaluation before using that executor in OpenShift.

## 8. Security requirements

- Operator authentication and downstream Basic Auth credentials must be independent.
- Credentials must be supplied via environment variables, mounted secrets, or Flowctl's encrypted secret storage, never committed to Git.
- Execution logs must redact passwords and `Authorization` headers.
- Query parameters must be validated and URL-encoded.
- Only predefined service endpoints may be called.
- Workflow execution must be authorized server-side.
- The mock services must not be exposed to the host network by default.
- The local PoC may use HTTP inside the isolated Compose network; a production deployment must use appropriate TLS protections.
- Container images must be pinned to specific versions or digests after validation.

## 9. Acceptance tests

| Test                                 | Expected result                         |
| ------------------------------------ | --------------------------------------- |
| Start Compose stack                  | All required containers become healthy  |
| Open Flowctl                         | Login page displayed                    |
| Login as operator                    | Authentication succeeds                 |
| Execute Service A lookup             | HTTP 200 and Service A JSON returned    |
| Execute Service B lookup             | HTTP 200 and Service B JSON returned    |
| Submit empty reference               | Validation prevents execution           |
| Use incorrect downstream credentials | HTTP 401, no secret leakage             |
| Access without login                 | Execution denied                        |
| Access workflow without role         | Execution denied                        |
| Inspect execution history            | Operator, timestamp and result recorded |
| Restart containers                   | Workflows and execution history persist |
| Enable Keycloak mode                 | OIDC login and role mapping work        |

## 10. Implementation priorities

First establish the official Flowctl Compose setup and confirm how its bootstrap authentication works. Next add the two downstream services, their credentials, and the workflows. Then verify role-based authorization and audit history. Finally introduce Keycloak and test OIDC login.

Important findings from the repository: Flowctl has an official Compose example with a working OIDC demonstration using Dex, so there is no need to invent an authentication integration. The presence of a bootstrap admin password does not, however, prove that Flowctl supports a full local Basic Auth login flow for ordinary operators. That must be verified. Likewise, the HTTP execution mechanism should be checked before treating the workflow YAML as runnable.

The specification above defines the intended PoC and acceptance criteria; it is not yet a tested, executable Compose implementation.
