# The `gate` job: the one required check of a ci.yml

The organisation requires checks through org rulesets. A required check per job
cannot be kept right: a job behind a `paths` filter or an `if:` does not run on
every pull request and would stay *expected* forever, and a new job would be
missing from the required list without anyone noticing. So every `ci.yml` gets
one collecting job with the fixed id and name `gate`, and only `gate` is
required.

`gate` runs always, after every other job of the file, and calls the action
[`.github/actions/gate`](../.github/actions/gate/action.yml):

- **green** when every job in `needs` ended in `success` or `skipped`;
- **red** as soon as one ended in `failure` or `cancelled` (or any other
  result), and red when `needs` is empty;
- a red gate names every red job with its result, as an annotation and in the
  job summary.

## The job to paste

Paste it as the last job of the `ci.yml`:

```yaml
  # The one required check of this file. EVERY NEW JOB OF THIS FILE BELONGS IN
  # THE needs LIST BELOW: a job missing there is not checked by anything that
  # blocks a merge.
  gate:
    name: gate
    needs: [build, test, lint]       # all other jobs of this file, none left out
    if: always()                     # also when a job before it failed, was cancelled or skipped
    runs-on: apollo                  # the same runs-on as the other jobs of this file
    timeout-minutes: 5
    steps:
      - uses: Kumbuka-ai/workflows/.github/actions/gate@6b44efe6b77f85e0f05923a1402e5f9029bf0888 # gate action
        with:
          needs: ${{ toJSON(needs) }}
```

## The parts that are not optional

| part | why |
|---|---|
| job id **and** `name:` exactly `gate` | the ruleset requires the check by this name; the check takes the job's `name:`, so both are `gate` |
| `needs:` with **all other jobs** of the file | a job not listed is not looked at; the gate stays green while it is red |
| `if: always()` | without it, a failed or cancelled job *skips* the gate, and a skipped required check counts as passed |
| the action pinned to a **commit SHA** | like every foreign action of the organisation: a branch or tag can move, a SHA cannot |
| `runs-on` as the other jobs of the file | the organisation builds on the runner `apollo`; a file that sends fork pull requests to a hosted runner uses its own expression here too |

**Every new job of the file belongs in the `needs` list of `gate`.** That is the
one thing this pattern cannot check for you; review it in every pull request
that adds a job.

`needs` takes job **ids**, and the gate names the red jobs by their ids. A job
with a matrix appears once, with the combined result of its legs.

## Notes

- The SHA above is the commit that introduced the action. When the action
  changes, move the pin to a commit on `main` that carries the change.
- Do not name any other job of a workflow `gate`: two checks of that name would
  both answer the ruleset.
- A workflow with a single job still gets a `gate`, so the required check has
  the same name in every repository.
