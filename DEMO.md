# Multi-Instance Looker CI/CD Demo Runbook

Walkthrough showing how the multi-instance CI/CD pipeline catches breaking changes, enforces settings parity, and promotes code across Dev, Stage (UAT), and Prod.

## 1. LookML Style Guide Linting (LAMS Rule F2)

Demonstrates automated LookML style enforcement via [manifest.lkml](manifest.lkml) and LAMS (`@looker/look-at-me-sideways`).

### Break the Rule (Demo)

1. On a feature branch, add a dimension in [views/users.view.lkml](views/users.view.lkml) without a `description:` parameter:

```lookml
dimension: is_adult {
  type: yesno
  sql: ${age} >= 18 ;;
}
```

2. Open a Pull Request. The `lams-lint` check fails and logs the violation directly in the build output:
   > `Rule F2: Field users.is_adult is missing a description.`

### Fix the Rule

Add the description parameter and push:

```lookml
dimension: is_adult {
  type: yesno
  description: "Indicates whether the user is 18 years of age or older."
  sql: ${age} >= 18 ;;
}
```

The `lams-lint` gate immediately turns green.

---

## 2. Breaking Change Detection via PR

This scenario demonstrates how automated CI validation catches breaking changes on Pull Requests before code reaches Stage or Production.

### Objective

Delete the `order_items.delete_me` measure on a feature branch and verify that the CI pipeline blocks merge.

### Create Feature Branch in Looker IDE

In your Looker Dev instance:

1. Ensure Development Mode is toggled on in the left navigation sidebar.
2. Open the project from the Develop navigation menu.
3. Click the Git branch selector in the top-left of the IDE (currently showing `main` or `production`).
4. Select Create Branch, enter `demo/delete-unused-measure`, and click Create.

### Delete the delete_me Measure

1. In the Looker IDE file browser, navigate to and open [views/order_items.view.lkml](views/order_items.view.lkml).
2. Locate and delete the `delete_me` measure:

```diff
- measure: delete_me {
-   type: count
-   description: "Demo count measure intended for CI/CD breaking change validation."
- }
```

3. Click Save Changes in the top-right corner of the editor.

### Commit and Open Pull Request

1. In the Git Actions panel in the top-right of the IDE, click Commit Changes & Push.
2. Enter a commit message such as `chore: remove delete_me measure` and confirm.
3. Click Open Pull Request to navigate to GitHub with the new branch pre-selected against `main`.
4. Submit the Pull Request to trigger the automated CI workflow [.github/workflows/pr-checks.yaml](.github/workflows/pr-checks.yaml).

### Review Failed Validation Gates

The PR checks fail and block merging with two distinct errors:

1. LookML unit tests fail in Dev because `test: order_items_delete_me_has_rows` in [models/cicd.model.lkml](models/cicd.model.lkml) references a field that no longer exists.
2. The Content Validator in Stage fails because the single-tile visualization in [dashboards/order_items_overview.dashboard.lookml](dashboards/order_items_overview.dashboard.lookml) depends on `order_items.delete_me`.

The PR conversation clearly identifies broken downstream dashboards and failing unit tests before any code touches the staging environment.

## Fix Breaking Changes and Promote to Stage

### Update Dependent Tests and Dashboards

To resolve the breaking change cleanly:

1. Update [models/cicd.model.lkml](models/cicd.model.lkml) to remove or update the obsolete test block.
2. Update [dashboards/order_items_overview.dashboard.lookml](dashboards/order_items_overview.dashboard.lookml) to replace `order_items.delete_me` with `order_items.count`.

Commit and push the updates:

```bash
git add models/cicd.model.lkml dashboards/order_items_overview.dashboard.lookml
git commit -m "fix: update dashboard and tests to use order_items.count"
git push origin demo/delete-unused-measure
```

### Verify Passing PR Gates (Dev Mode First)

All validation gates execute in Looker's `dev` workspace first before any code is deployed to production:

1. The runner authenticates via Looker CLI and generates a token in `--token-file`.
2. Switches the CI session workspace to `dev` mode.
3. Checks out the PR branch from `main`.
4. Runs LookML validation and Content Validator against the target environment in Dev mode.

Using Looker CLI ([looker-open-source/looker-cli](https://github.com/looker-open-source/looker-cli)):

```bash
# Extract clean host (without https://) and use port 443 for Looker Cloud
STAGE_HOST=$(echo "$LOOKER_STAGE_BASE_URL" | sed -e 's|^https\?://||' -e 's|/.*$||')

# 1. Login and persist session token to token file
looker-cli session login \
  --host "$STAGE_HOST" \
  --port 443 \
  --client-id "$LOOKER_STAGE_CLIENT_ID" \
  --client-secret "$LOOKER_STAGE_CLIENT_SECRET"

# 2. Switch workspace to dev mode
echo '{"workspace_id":"dev"}' | looker-cli api session update_session - \
  --token-file \
  --host "$STAGE_HOST" \
  --port 443

# 3. Check out the PR branch from main on Stage
looker-cli project checkout cicd_demo demo/delete-unused-measure \
  --token-file \
  --host "$STAGE_HOST" \
  --port 443

# 4. Run LookML validation and Content Validator in Dev Mode
looker-cli project validate cicd_demo \
  --token-file \
  --host "$STAGE_HOST" \
  --port 443

looker-cli api content content_validation \
  --project_names "multi-instance-cicd-demo" \
  --token-file \
  --host "$STAGE_HOST" \
  --port 443
```

### Merge to main for Stage Deployment

Merge the Pull Request into `main`. The [.github/workflows/deploy-stage.yaml](.github/workflows/deploy-stage.yaml) workflow runs automatically:

- Calls the Looker Advanced Deploy API via `looker-cli api project deploy_ref_to_production` to deploy the merge commit SHA to Stage.
- Compares Stage and Prod settings via `looker-cli api config get_setting` and `diff -u` to confirm settings parity.
- UAT can proceed on Stage under identical settings to Production.

## Release to Production via Version Tag

Once UAT is complete and approved:

1. Publish a GitHub Release with semantic tag `v1.0.0`.
2. [.github/workflows/release-prod.yaml](.github/workflows/release-prod.yaml) runs the Dev-Mode-First gate on Production:
   - Switches Prod session to `dev` mode via `--token-file`.
   - Checks out the release tag ref `tags/v1.0.0`.
   - Runs Content Validator and SQL validation.
   - Triggers and validates Persistent Derived Table (PDT) builds in Dev Mode to pre-warm warehouse tables and verify DDL execution.
3. Only after all Dev Mode checks and PDT builds pass, deploys the release tag to Production:
   ```bash
   PROD_HOST=$(echo "$LOOKER_PROD_BASE_URL" | sed -e 's|^https\?://||' -e 's|/.*$||')

   looker-cli api project deploy_ref_to_production cicd_demo \
     --ref tags/v1.0.0 \
     --token-file \
     --host "$PROD_HOST" \
     --port 443
   ```
4. Only after the release deploy succeeds, automatically promotes whitelisted Shared folders and Boards strictly from **Stage > Prod** in the final release job (or on-demand via [.github/workflows/promote-udd-content.yaml](.github/workflows/promote-udd-content.yaml)).

Dev content is never promoted automatically. The Dev instance is an experimentation sandbox. To promote dashboards created in Dev, convert them into LookML Dashboards (`.dashboard.lookml`) so they track in Git and deploy across all environments, or use adhoc Looker CLI commands (`looker-cli dashboard export/import`) for one-off manual syncs.
