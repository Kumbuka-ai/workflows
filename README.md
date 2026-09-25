# Shared CI security gates

Semgrep OSS, Trivy and Gitleaks as reusable workflows, called by the
repositories of this organisation. One definition for all of them: copied into
each repository the checks drift apart, and a rule change has to be made once
per repository instead of once.

## Why this repository is public

It has to be. GitHub allows a private repository to share its workflows only
with other private repositories — "access is allowed only from private
repositories". A public repository cannot call them at all. Since the gates are
meant to cover every repository, the definition has to live somewhere every
repository can reach.

Nothing here is confidential: pinned scanner digests, a community rule set, and
the logic that decides what turns a run red.

## Using it

```yaml
name: security

on:
  push:
    branches: [main]
  pull_request:
  schedule:
    - cron: "17 4 * * *"   # offset the minute per repository
  workflow_dispatch:

permissions:
  contents: read

jobs:
  security:
    uses: Kumbuka-ai/workflows/.github/workflows/reusable-security.yml@main

  # Only where the repository ships a container image.
  security-images:
    uses: Kumbuka-ai/workflows/.github/workflows/reusable-security-image.yml@main
    permissions:
      contents: read
      packages: read      # required — the called workflow cannot be granted
                          # a permission the caller does not hold
    with:
      image-targets: >-
        [{"name": "app", "context": ".", "file": "Dockerfile"}]
```

The daily `schedule` is not decoration. Everything below depends on the scan
actually running, and a repository nobody pushes to would otherwise never learn
that a new CVE was published — nor that a fix it has been waiting for arrived.

## What turns a run red

Each tool runs as a job that **fails** on a finding. That is the whole design: a
check whose result lands somewhere nobody looks is not a check.

| job | checks | blocks on |
|---|---|---|
| `semgrep` | static analysis, pinned `p/default` snapshot | any finding |
| `trivy-fs` | dependencies, filesystem, configuration | HIGH and CRITICAL **that have a fix** |
| `trivy-image` | the container image, including OS packages | HIGH and CRITICAL **that have a fix** |
| `gitleaks` | secrets in the working tree and full history | any finding |

### Only a fixable vulnerability blocks

A CVE upstream has not fixed is not a task, it is a state. Base images routinely
carry OS packages whose CVEs report `fixed:-`, meaning no patch exists anywhere.
Blocking on those makes a job permanently red without a single action anyone
could take — and a gate that is red for reasons nobody can act on gets ignored,
which is worse than no gate at all.

**Nothing is hidden.** Every finding is in the report and the job summary, and
unfixed ones are raised as a warning naming package and CVE. What changes is
only which of them stops the run.

The mechanism is the point: an unfixed CVE blocks nothing today, and **the
moment upstream publishes a fix it stops being unfixed and blocks by itself**.
Nobody has to notice, keep a list, or remember to look.

### Every job proves it looked at something

A scanner reporting "no findings" because it saw nothing is the main failure
mode of these tools, and it is indistinguishable from success. So each job
asserts a non-empty search space and fails when it is empty — with one
distinction that matters: a repository carrying no package manifest at all
legitimately resolves zero dependency targets, and that is reported, not failed.
Manifests present but nothing resolved *is* a failure.

## Exceptions

A fix that exists but cannot be adopted yet belongs in a `.trivyignore.yaml` at
the root of the repository it concerns:

```yaml
vulnerabilities:
  - id: CVE-0000-00000
    statement: >-
      Fixed upstream in x.y.z, but the version here is the one the base image
      ships. Adopting it means a new base image, not a change we can make.
    expired_at: 2026-12-31
```

Three rules, and they are what keep the register from becoming a place where
problems go to be forgotten:

1. **Never without a reason.** `statement` says why this cannot be fixed here.
2. **Never without an expiry.** `expired_at` is mandatory. When it passes, the
   entry stops suppressing and the run goes red again — forcing the decision to
   be taken a second time rather than lapse quietly.
3. **Never in this repository.** The register lives where the risk is carried.

## Pinning

| tool | version | pin |
|---|---|---|
| Semgrep OSS | 1.178.0 | image digest |
| Trivy | 0.74.0 | image digest |
| Gitleaks | 8.30.1 | image digest |
| Semgrep rules | `p/default`, 1073 rules | snapshot in this tree |

Digests rather than tags: a tag can be repointed at another build, and a scanner
that silently changes version silently changes its verdict.

The Semgrep rules are a snapshot rather than a registry reference for the same
reason, plus one more — a registry outage would turn a green run into a check
that looked at nothing.

**Deliberately not pinned:** the Trivy vulnerability database, because a feed
that cannot learn about yesterday's CVE is worse than useless; and the `@main`
callers use here, because what must not drift is the *verdict*, while a change
to the checks themselves has to reach every repository at once.

To refresh the rules:

```sh
curl -s https://semgrep.dev/c/p/default > .github/actions/semgrep-scan/rules/semgrep-p-default.yaml
```

and restore the header. Review the diff — it is the verdict changing.
