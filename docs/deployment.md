# Deploying and rolling back

This app runs on DigitalOcean App Platform in two environments, each its own App Platform app:

| Environment | App Platform app | Spec | Datacenter / VPC (`.do/environments.yaml`) |
|---|---|---|---|
| `qa` | `testdigitalocean-qa` | `.do/app.qa.yaml` | `sfo3` / `default-sfo3` |
| `production` | `testdigitalocean` | `.do/app.production.yaml` | `sfo3` / `default-sfo3` |

Two GitHub Actions workflows handle releases:

| Workflow | File | Trigger | What it does |
|---|---|---|---|
| **Build and publish container** | `.github/workflows/docker-publish.yml` | Automatic on push to `main` and `v*.*.*` tags (also manual) | Builds the image, pushes it to GHCR, and creates a **release manifest** |
| **Deploy to App Platform** | `.github/workflows/deploy.yml` | Manual only | Deploys a release manifest to QA or production, or rolls an environment back |

Building never deploys. Every deploy is a deliberate, manual run of the deploy workflow.

The normal flow is **build → deploy to QA → check QA → deploy the same build to production**. Production refuses a build that hasn't been deployed to QA, unless you mark the deploy as a hotfix.

## How releases work

Every build of `main` or a version tag uploads a workflow artifact named **`release-manifest`**. It contains:

- `manifest.json`: what was built, where it came from, and the exact image digest.
- `app.qa.yaml` and `app.production.yaml`: copies of both App Platform specs from that commit.
- `environments.yaml`: a copy of each environment's datacenter and VPC from that commit.

```json
{
  "schemaVersion": 3,
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
  "specs": {
    "qa":         { "file": "app.qa.yaml",         "sha256": "…" },
    "production": { "file": "app.production.yaml", "sha256": "…" }
  },
  "config": { "file": "environments.yaml", "sha256": "…" }
}
```

The deploy workflow deploys a manifest, not a tag. That has three effects:

- **The image is pinned by digest.** You get exactly the image that build produced, even if a tag such as `latest` or `main` has since moved.
- **The spec and location come from the manifest.** Each environment gets its own spec, datacenter and VPC as they were at that commit. Rolling back restores the old image *and* the old spec (env vars, health check, instance size, and so on) and location, not what's currently on `main`.
- **QA and production run the same image.** Promoting a build to production deploys the identical digest that was tested in QA.

After each successful deploy, the workflow uploads a **`deployed-release-qa`** or **`deployed-release-production`** artifact: the bundle, plus a `deployment.json` recording the environment, region, datacenter and VPC (name and ID), when it was deployed, by whom, whether it was a rollback or a hotfix, and the App Platform app, URL and deployment IDs. Rollbacks and the production QA check use these artifacts.

Each deploy run is titled after its environment, for example `Deploy qa - build 123456`, `Deploy production - rollback` or `Deploy production - build 123456 - hotfix`, so the run list shows at a glance what went where.

## Deploy to QA

1. Wait for the **Build and publish container** run for your commit to finish successfully. Note its run ID: it's the number at the end of the run's URL (`…/actions/runs/123456`) and is also printed in the run summary under **Release manifest**.
2. Go to **Actions → Deploy to App Platform → Run workflow**.
3. Set **environment** to `qa`.
4. Enter the build's run ID in **build_run_id**. If you leave it blank, the workflow deploys the most recent successful push build of the branch or tag picked in **Use workflow from** (usually `main`).
5. Click **Run workflow**.

## Promote to production

1. Check the build in QA.
2. Go to **Actions → Deploy to App Platform → Run workflow**.
3. Set **environment** to `production` and enter the **same build_run_id** you deployed to QA.
4. Click **Run workflow**.

The **Require QA deploy** step looks through recent successful QA deploys for one with the same image digest and fails the run if there isn't one:

```
Image sha256:… has not been deployed to QA. Deploy this build to QA first, or tick skip_qa_check for a hotfix.
```

> Leaving **build_run_id** blank for production picks the latest build, which may not be the one you tested in QA. Pass the run ID explicitly when promoting.

## Hotfix: deploy to production without QA

When a fix can't wait for QA:

1. Go to **Actions → Deploy to App Platform → Run workflow**.
2. Set **environment** to `production`, enter the **build_run_id**, and tick **skip_qa_check**.
3. Click **Run workflow**.

The QA check is skipped with a warning annotation, the run is titled `… - hotfix`, and `deployment.json` records `"qaCheckSkipped": true`. Deploy the same build to QA afterwards so QA matches production again.

**skip_qa_check** is ignored for QA deploys and rollbacks.

## Roll back

Rollbacks are per environment: rolling back QA never touches production, and vice versa.

### One step back

1. Go to **Actions → Deploy to App Platform → Run workflow**.
2. Set **environment** to the environment to roll back.
3. Tick **rollback** (leave **build_run_id** blank; it is ignored when rollback is ticked).
4. Click **Run workflow**.

This redeploys the release from that environment's deploy *before* its most recent successful one. Production rollbacks skip the QA check, since they restore something production already ran.

> **Rolling back twice undoes the first rollback.** The rollback itself becomes the environment's most recent deploy, so a second rollback swaps you back to the release you rolled away from. To go further back, use a specific build.

### Further back

Deploy that build by its run ID to the environment, as in [Deploy to QA](#deploy-to-qa). To find which build was live at a given time, open that environment's past **Deploy to App Platform** runs: each run summary shows the full manifest that was deployed, including `build.runId`.

To take production further back than one step, the build normally has to have been in QA. It usually was; if its QA deploy artifact has expired, tick **skip_qa_check**.

## What the deploy workflow does

1. **Fetch release manifest.** Downloads the `release-manifest` artifact from the build run, or, when rolling back, the `deployed-release-<environment>` artifact from that environment's previous deploy.
2. **Validate release manifest.** Checks `schemaVersion`, picks the environment's spec, verifies the spec's and `environments.yaml`'s SHA-256 against the manifest, and reads the environment's datacenter and VPC.
3. **Require QA deploy** (production only, not on rollback). Confirms the image digest was deployed to QA, unless **skip_qa_check** is ticked.
4. **Verify image exists.** Confirms `ghcr.io/<name>@<digest>` is still in GHCR.
5. **Resolve region and VPC.** Maps the datacenter to its App Platform region (`sfo3` → `sfo`), looks up the VPC's ID by name, and checks the VPC is in that datacenter.
6. **Render app spec.** Substitutes `${IMAGE_DIGEST}` and `${GHCR_CREDENTIALS}` into the environment's spec, and sets `region` and `vpc.id` (or leaves `vpc` out when no VPC is configured).
7. **Deploy to App Platform.** Runs `doctl apps create --spec … --upsert --wait`, which updates the app with the spec's `name` (creating it on the first deploy) and blocks until App Platform finishes the deployment.
8. **Record deployment.** Writes `deployment.json` and uploads the `deployed-release-<environment>` artifact.

Deploys to the same environment run one at a time (concurrency group `deploy-<environment>`); a second run waits for the first to finish rather than cancelling it. QA and production deploys don't wait on each other.

The job runs in the GitHub environment of the same name (`qa` or `production`), so any protection rules on that environment apply.

## Triggering from the command line

With the GitHub CLI:

```sh
# Find build run IDs
gh run list --workflow docker-publish.yml --branch main --status success

# Deploy a build to QA, then promote it to production
gh workflow run deploy.yml --ref main -f environment=qa -f build_run_id=123456
gh workflow run deploy.yml --ref main -f environment=production -f build_run_id=123456

# Hotfix straight to production
gh workflow run deploy.yml --ref main -f environment=production -f build_run_id=123456 -f skip_qa_check=true

# Roll back production one step
gh workflow run deploy.yml --ref main -f environment=production -f rollback=true
```

Without the CLI, call the REST API with a token that has `actions: write` on the repository:

```sh
curl -X POST \
  -H "Authorization: Bearer $GITHUB_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  https://api.github.com/repos/JonHagerman/testdigitalocean/actions/workflows/deploy.yml/dispatches \
  -d '{"ref":"main","inputs":{"environment":"qa","build_run_id":"123456"}}'
```

## Required configuration

| Name | Kind | Used for |
|---|---|---|
| `DIGITALOCEAN_ACCESS_TOKEN` | Secret | `doctl` authentication |
| `GHCR_CREDENTIALS` | Secret | App Platform pulling the private image; format `username:token`, where the token is a classic PAT with `read:packages` |
| `qa` | Environment | QA deploy job environment |
| `production` | Environment | Production deploy job environment |

The two secrets are repository secrets shared by both environments. To give an environment its own value (for example, a DigitalOcean token for a separate team), add a secret with the same name to that GitHub environment; it overrides the repository secret.

Recommended protection rules, under **Settings → Environments**:

- `production`: restrict **Deployment branches and tags** to `main` and `v*` tags, and add **Required reviewers**, so every production deploy, hotfix and rollback waits for approval.
- `qa`: none.

The built-in `GITHUB_TOKEN` covers listing runs, downloading artifacts, and checking the image in GHCR (`actions: read`, `packages: read`).

## Changing an environment

Edit `.do/app.qa.yaml`, `.do/app.production.yaml` or `.do/environments.yaml` and commit. The change ships with the next build, and only takes effect when that build is deployed to the environment. Rolling back to an earlier release restores that release's spec and location too.

In the spec files:

- Leave `${IMAGE_DIGEST}` and `${GHCR_CREDENTIALS}` alone: the deploy fills them in.
- Leave out `region` and `vpc`: the deploy sets them from `environments.yaml`.
- Keep the `name`: it's how `--upsert` finds the app. Changing it creates a new App Platform app with a new URL.

### Datacenter and VPC

`.do/environments.yaml` sets where each environment runs:

```yaml
qa:
  datacenter: sfo3
  vpc: default-sfo3

production:
  datacenter: sfo3
  vpc: default-sfo3
```

- **datacenter:** App Platform runs apps in regions (such as `sfo`), and each region can only attach VPCs in one datacenter. The supported datacenters are `ams3`, `atl1`, `blr1`, `fra1`, `lon1`, `nyc1`, `sfo3`, `sgp1`, `syd1` and `tor1`. Any other datacenter, such as `sfo2`, fails the deploy. To reach resources in another datacenter, peer that datacenter's VPC with the app's VPC.
- **vpc:** the name of a VPC in that datacenter, as shown by `doctl vpcs list` or under **Networking → VPC**. The deploy fails if it doesn't exist or is in another datacenter. Set it to `""` to deploy without a VPC.

Changing the datacenter of an existing app redeploys the same app (and URL) in the new region. Any database the app uses stays where it is. VPCs can't be used together with dedicated egress IPs.

## Limitations

- **Artifacts expire after 90 days.** A build older than that can't be deployed, and a rollback target older than that can't be restored. Rebuild the commit to get a fresh manifest. The QA check also only sees QA deploys whose artifacts haven't expired.
- **The QA check looks at the 100 most recent successful deploys.** A build deployed to QA longer ago than that needs **skip_qa_check** or a fresh QA deploy.
- **Pull request builds don't produce a manifest** and can't be deployed. Their images aren't pushed.
- **Builds from before `environments.yaml` can't be deployed.** Their manifests (`schemaVersion` 1 or 2) don't record a datacenter or VPC, and deploying them would move the app back to its old region. A rollback that lands on one fails at **Validate release manifest**; deploy a newer build by `build_run_id` instead.

## Troubleshooting

| Error | Cause and fix |
|---|---|
| `No successful build found for <ref>` | No successful push build exists for that branch or tag. Check the **Use workflow from** selection, or pass `build_run_id`. |
| `no artifact matches any of the names or patterns provided` | The run has no manifest: it is a PR build, or the artifact expired. Pick another build or rebuild the commit. |
| `No earlier successful <environment> deploy to roll back to` | That environment has fewer than two successful deploys. Deploy by `build_run_id` instead. |
| `Image … has not been deployed to QA` | Deploy the build to QA first, or tick **skip_qa_check** for a hotfix. |
| `Release uses manifest schemaVersion …; only 3 is supported` | The build predates `environments.yaml`. Deploy a newer build. |
| `App Platform can't run in datacenter '…'` | Set the environment's `datacenter` in `.do/environments.yaml` to a supported one (see [Datacenter and VPC](#datacenter-and-vpc)), then rebuild. |
| `VPC '…' not found` or `VPC '…' is in …, not …` | Create the VPC in that datacenter, or set `vpc` to an existing VPC there (or `""`), then rebuild. |
| `…: FAILED` (checksum) | The spec in the bundle doesn't match the manifest. Don't deploy it; rebuild the commit. |
| `Verify image exists` fails | The image was deleted from GHCR. Rebuild the commit. |
| `Deploy to App Platform` fails | Check the deployment logs in the DigitalOcean control panel. A failed deploy isn't recorded, so the next rollback still targets the environment's last good release. |
