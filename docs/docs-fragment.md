<!--
Copyright (c) 2026 JBAConsult - Architekturberatung Johannes Bayer-Albert
All rights reserved. Copying, reproduction, distribution or any other
use of this file, in whole or in part, without the prior written
permission of the copyright holder is prohibited.
-->
# The documentation fragment of a module

Every module produces, in its own CI at its release tag, a small machine-readable
description of what it shipped, and puts it on GHCR. Whoever documents the
platform as delivered collects these fragments and assembles them; it never
reads a code repository. A missing fragment is a finding of that collector,
never a failure of the release — so the job that produces it **must not block a
release** (see [Hanging it in](#hanging-it-in-non-blocking)).

This document is the contract. The schema of `fragment.json` is
[`docs-fragment.schema.json`](docs-fragment.schema.json) next to it; the job is
[`.github/workflows/reusable-docs-fragment.yml`](../.github/workflows/reusable-docs-fragment.yml),
the scripts it runs are under [`scripts/docs-fragment/`](../scripts/docs-fragment/).

## Content

A fragment is two things:

```text
fragment.json     the fragment, below
plantuml/         the module's views as C4-PlantUML, one .puml per view
```

### `fragment.json`

| field | content |
|---|---|
| `schema_version` | `"1.0"`, as `major.minor` |
| `module` | the module's name, lower case: `^[a-z0-9]+([._-][a-z0-9]+)*$` |
| `version` | the release tag the fragment was produced at, as the module writes it (`v1.2.3` or `1.2.3`); a valid OCI tag |
| `commit` | the full SHA-1 of the commit the fragment was produced from |
| `produced_at` | UTC, `YYYY-MM-DDTHH:MM:SSZ` |
| `workspace` | a [Structurizr](https://structurizr.com/) workspace of the module in its JSON form |

All six are required; a fragment without one of them fails the schema.

**A reader skips every field it does not know.** The schema allows unknown
fields on purpose. A later optional part — prose from the build, say — is added
as a new field under a new minor version (`1.1`), and a reader of `1.x` keeps
working. A change that a `1.x` reader cannot skip raises the major version; a
reader refuses a major version it does not know.

### The workspace

The module is the **content of a C4 container**. The deployment unit the module
belongs to is not the module's to know — that mapping belongs to the collector's
frame, where each container names its modules. So the workspace holds:

- one software system, a carrier with the module's name and id `"1"`; the
  collector replaces it with the system of its frame;
- in it one container, the module, with id `"2"`, carrying the properties
  `module`, `version`, `commit`, `build.manifests` (every build manifest git
  tracks in the module — `pom.xml`, `package.json`, `go.mod`, `Cargo.toml`,
  Gradle files, `pyproject.toml`, `Dockerfile`, `Containerfile` — as paths,
  sorted, comma-separated) and `build.systems`; its `technology` names the
  build systems at the root of the tree (`Maven`, `Gradle`, `Node.js`, `Go`,
  `Rust`, `Python`);
- one container view of it, key `<module>-container`.

**Components only where they can be derived without an assumption.** The basic
version derives none: which parts of a module are C4 components is not
something its file list says, and a guessed component is worse than a missing
one. Whether a component finder can derive them from the code is to be
measured on a real module before it is relied on; until then `components` is
absent. No prose and no model call is part of the job.

### `plantuml/`

One file per view of the workspace, `<view key>.puml`, using the C4 macros of
PlantUML's standard library (`!include <C4/C4_Container>`), so rendering needs
no network. The views are exported from `fragment.json` alone and say nothing
the workspace does not.

### Reproducible

Produced twice from the same commit, `fragment.json` is **byte-identical except
for the line of `produced_at`**, and `plantuml/` is byte-identical: keys are
sorted, element ids are fixed, the list of manifests is sorted bytewise, and
only files git tracks count, so build output left in a checkout changes
nothing. The self-test checks this on every pull request.

## Storage: one OCI artefact on GHCR

| | |
|---|---|
| name | `ghcr.io/<owner>/<repository>-docs-fragment`, lower case, from the calling repository — for `Kumbuka-ai/Example-Module`: `ghcr.io/kumbuka-ai/example-module-docs-fragment` |
| tags | the release tag; when it reads `vX.Y.Z…`, also `X.Y.Z…` — so the fragment is found under either form a module publishes its image with |
| artefact type | `application/vnd.kumbuka.docs-fragment.v1` |
| layer `fragment.json` | `application/vnd.kumbuka.docs-fragment.fragment.v1+json` |
| layer `plantuml` | `application/vnd.kumbuka.docs-fragment.plantuml.v1.tar+gzip`, the directory |
| annotations | `org.opencontainers.image.version` (release tag), `.revision` (commit), `.source` (the repository) |

The suffix `-docs-fragment` and the artefact type of its own keep the fragment
apart from the module's image: it never shares a name with it, and a client
that pulls images does not take it for one.

To read one:

```sh
oras pull ghcr.io/kumbuka-ai/example-module-docs-fragment:v1.2.3 -o fragment/
```

## Hanging it in, non-blocking

In the module's release workflow, the job that runs at the release tag:

```yaml
  # The documentation fragment of this release. NON-BLOCKING ON PURPOSE: a
  # missing fragment is a finding, never a reason to hold a release. So no job
  # of this file needs this one, and it is NOT in the needs list of `gate`.
  # (continue-on-error is carried by the called jobs; GitHub refuses it here.)
  docs-fragment:
    uses: Kumbuka-ai/workflows/.github/workflows/reusable-docs-fragment.yml@main
    if: startsWith(github.ref, 'refs/tags/')   # only where the file also runs on other events
    permissions:
      contents: read
      packages: write     # for the publish job; the caller must hold what the called jobs declare
    with:
      module: ${{ github.event.repository.name }}   # must be lower case; write it out where the name is not
      version: ${{ github.ref_name }}
      publish: true
      runs-on: apollo     # the runner of the module's other jobs; public repositories leave it out
```

The three parts that keep it non-blocking:

| part | why |
|---|---|
| `continue-on-error: true` on every job of the called workflow | a failed fragment job does not turn the run red. It sits there and not on the calling job because GitHub refuses `continue-on-error` on a job that calls a reusable workflow — the workflow file does not start at all (measured in this repository's self-test). So it cannot be forgotten by a caller either. |
| no `needs: docs-fragment` anywhere | no release step waits for it or is skipped because it failed |
| not in the `needs` of `gate` ([gate-job.md](gate-job.md)) | the one required check does not look at it; this is the single exception to "every job of the file belongs in `gate`" |

The self-test of this repository calls the workflow exactly so, with a fragment
job that fails on purpose, and checks that the job failed and the run stays
green.

Inputs: `module` and `version` (required), `publish` (default `false`: produce,
check and keep the fragment as a workflow artefact `docs-fragment-<module>`
without touching GHCR), `runs-on` (default `ubuntu-latest`), `tools-ref` (the
ref of this repository the scripts and the schema come from, default `main`).

Rights: `contents: read` throughout; `packages: write` only in the publish job,
which runs only with `publish: true` and pushes with the caller's
`GITHUB_TOKEN`. No other secret.
