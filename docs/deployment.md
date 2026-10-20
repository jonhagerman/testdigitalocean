# Deploying and rolling back

This app runs on DigitalOcean App Platform. Two GitHub Actions workflows handle releases:

| Workflow | File | Trigger | What it does |
|---|---|---|---|
| **Build and publish container** | `.github/workflows/docker-publish.yml` | Automatic on push to `main` and `v*.*.*` tags (also manual) | Builds the image, pushes it to GHCR, and creates a **release manifest** |
| **Deploy to App Platform** | `.github/workflows/deploy.yml` | Manual only | Deploys a release manifest to App Platform, or rolls back to the previous one |

Building never deploys. Every deploy is a deliberate, manual run of the deploy workflow.

## How releases work

Every build of `main` or a version tag uploads a workflow artifact named **`release-manifest`**. It contains:

- `manifest.json`: what was built, where it came from, and the exact image digest.
- `app.yaml`: a copy of the App Platform spec (`.do/app.yaml`) from that commit.

```json
{
  "schemaVersion": 1,
  "app": "testdigitalocean",
  "version": "main",
  "commit": "14cc3de…",
  "ref": "refs/heads/main",
  "build": { "runId": 123456, "runUrl": "https://github.com/…/actions/runs/123456", "builtAt": "2026-10-20T21:39:01Z" },
  "image": {
    "registry": "ghcr.io",
    "name": "jonhagerman/testdigitalocean",
    "digest": "sha256:…",
    "tags": ["main", "sha-14cc3de", "latest"]
  },
  "spec": { "file": "app.yaml", "sha256": "…" }
}
```

The deploy workflow deploys a manifest, not a tag. That has two effects:

- **The image is pinned by digest.** You get exactly the image that build produced, even if a tag such as `latest` or `main` has since moved.
- **The spec comes from the manifest.** Rolling back restores the old image *and* the old spec (env vars, health check, instance size, and so on), not the spec currently on `main`.

After each successful deploy, the workflow uploads a **`deployed-release`** artifact: the manifest, the spec, and a `deployment.json` recording when it was deployed, by whom, whether it was a rollback, and the App Platform app and deployment IDs. Rollbacks use these artifacts.

## Deploy

### Latest build of a branch or tag

1. Wait for the **Build and publish container** run for your commit to finish successfully.
2. Go to **Actions → Deploy to App Platform → Run workflow**.
3. In **Use workflow from**, pick the branch or tag to deploy (usually `main`).
4. Leave **build_run_id** blank and **rollback** unticked.
5. Click **Run workflow**.

The workflow picks the most recent successful push build of that branch or tag.

### A specific build

1. Find the build's run ID. Open the **Build and publish container** run; the ID is the number at the end of the URL (`…/actions/runs/123456`), and it is also printed in the run summary under **Release manifest**.
2. Go to **Actions → Deploy to App Platform → Run workflow**.
3. Enter the ID in **build_run_id** and leave **rollback** unticked.
4. Click **Run workflow**.

## Roll back

### One step back

1. Go to **Actions → Deploy to App Platform → Run workflow**.
2. Tick **rollback** (leave **build_run_id** blank; it is ignored when rollback is ticked).
3. Click **Run workflow**.

This redeploys the release from the deploy *before* the most recent successful one.

> **Rolling back twice undoes the first rollback.** The rollback itself becomes the most recent deploy, so a second rollback swaps you back to the release you rolled away from. To go further back, use a specific build.

### Further back

Deploy that build by its run ID, as in [A specific build](#a-specific-build). To find which build was live at a given time, open past **Deploy to App Platform** runs: each run summary shows the full manifest that was deployed, including `build.runId`.

## What the deploy workflow does

1. **Fetch release manifest.** Downloads the `release-manifest` artifact from the build run, or the `deployed-release` artifact from the previous deploy when rolling back.
2. **Validate release manifest.** Checks `schemaVersion` and verifies the spec file's SHA-256 against the manifest.
3. **Verify image exists.** Confirms `ghcr.io/<name>@<digest>` is still in GHCR.
4. **Render app spec.** Substitutes `${IMAGE_DIGEST}` and `${GHCR_CREDENTIALS}` into the spec.
5. **Deploy to App Platform.** Runs `doctl apps create --spec … --upsert --wait`, which blocks until App Platform finishes the deployment.
6. **Record deployment.** Writes `deployment.json` and uploads the `deployed-release` artifact.

Deploys run one at a time (concurrency group `deploy-production`); a second run waits for the first to finish rather than cancelling it. The job uses the `production` environment, so any protection rules on that environment (required reviewers, branch restrictions) apply.

## Triggering from the command line

With the GitHub CLI:

```sh
# Latest build of main
gh workflow run deploy.yml --ref main

# A specific build
gh workflow run deploy.yml --ref main -f build_run_id=123456

# Roll back one step
gh workflow run deploy.yml --ref main -f rollback=true

# Find build run IDs
gh run list --workflow docker-publish.yml --branch main --status success
```

Without the CLI, call the REST API with a token that has `actions: write` on the repository:

```sh
curl -X POST \
  -H "Authorization: Bearer $GITHUB_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  https://api.github.com/repos/JonHagerman/testdigitalocean/actions/workflows/deploy.yml/dispatches \
  -d '{"ref":"main","inputs":{"build_run_id":"123456","rollback":"false"}}'
```

## Required configuration

| Name | Kind | Used for |
|---|---|---|
| `DIGITALOCEAN_ACCESS_TOKEN` | Secret | `doctl` authentication |
| `GHCR_CREDENTIALS` | Secret | App Platform pulling the private image; format `username:token`, where the token is a classic PAT with `read:packages` |
| `production` | Environment | Deploy job environment; add protection rules here |

The built-in `GITHUB_TOKEN` covers listing runs, downloading artifacts, and checking the image in GHCR (`actions: read`, `packages: read`).

## Limitations

- **Artifacts expire after 90 days.** A build older than that can't be deployed, and a rollback target older than that can't be restored. Rebuild the commit to get a fresh manifest.
- **The first rollback needs two deploys on this workflow.** Deploys from before release manifests existed have no `deployed-release` artifact, so a rollback fails until two new-style deploys have completed. Deploy by `build_run_id` instead in the meantime.
- **Pull request builds don't produce a manifest** and can't be deployed. Their images aren't pushed.

## Troubleshooting

| Error | Cause and fix |
|---|---|
| `No successful build found for <ref>` | No successful push build exists for that branch or tag. Check the **Use workflow from** selection, or pass `build_run_id`. |
| `no artifact matches any of the names or patterns provided` | The run has no manifest: it is a PR build, it predates manifests, or the artifact expired. Pick another build or rebuild the commit. |
| `No earlier successful deploy to roll back to` | Fewer than two successful deploys exist. Deploy by `build_run_id` instead. |
| `release/app.yaml: FAILED` (checksum) | The spec in the bundle doesn't match the manifest. Don't deploy it; rebuild the commit. |
| `Verify image exists` fails | The image was deleted from GHCR. Rebuild the commit. |
| `Deploy to App Platform` fails | Check the deployment logs in the DigitalOcean control panel. A failed deploy isn't recorded, so the next rollback still targets the last good release. |
