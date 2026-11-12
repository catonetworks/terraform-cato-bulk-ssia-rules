# terraform-cato-bulk-ssia-rules

Bulk-manages the Cato **SDP Static IP Allocation (sdpStaticIpAllocation)** policy from a single
JSON export: sections and rules (flat policy - no sub-policies exist for this
type), with ordering and publishing via `cato_bulk_ssia_move_rule`.

## Usage

The module reads a JSON configuration file that defines:
- **Rules**: Individual SDP Static IP Allocation rules with their configurations
- **Sections**: Logical groupings for organizing rules
- **Rule ordering**: Defines which rules belong to which sections and their order within sections

### Basic Example

```hcl
module "ssia_rules" {
  source = "catonetworks/bulk-ssia-rules/cato"

  ssia_rules_json_file_path = "${path.module}/config_data/all_ssia_rules_and_sections.json"
}
```

### JSON Configuration Structure

The JSON file should contain a nested structure with the following key components:

- `data.policy.sdpStaticIpAllocation.policy.rules[]` - Array of SDP Static IP Allocation rules
- `data.policy.sdpStaticIpAllocation.policy.sections[]` - Array of sections with index and name
- `data.policy.sdpStaticIpAllocation.policy.rules_in_sections[]` - Mapping of rules to sections with ordering

#### Key Fields:

**Rules Array**: Each rule is wrapped as `{audit, rule, properties}` (ids retained
for brownfield import) and contains: `name`, `enabled`, `description` (optional),
`ip` (the static IP being allocated), and `source.user` (a single user reference,
by `name` or `id`).

**Sections Array**: Defines sections with:
- `section_index`: The order of the section in the policy
- `section_name`: The display name of the section

**Rules in Sections Array**: Maps rules to sections with:
- `index_in_section`: The order of the rule within its section
- `section_name`: The section this rule belongs to (`""` for rules at the policy root)
- `rule_name`: The name of the rule to place in the section

### How Rule Ordering Works

Given a `rules_in_sections` entry like:

```json
{
  "index_in_section": 1,
  "section_name": "My SSIA Section",
  "rule_name": "My SSIA Rule"
}
```

the module places `"My SSIA Rule"` as the first rule inside `"My SSIA Section"`,
and `cato_bulk_ssia_move_rule.all_ssia_rules` republishes the policy with that
section/rule ordering (`section_index`, `index_in_section`) applied. Rows with
`section_name: ""` have no managed section to order within - they're excluded
from the move resource and surfaced via the `unordered_rules` output instead;
their order is creation order only.

### Parameters

- `ssia_rules_json_file_path`: Path to your JSON configuration file
- `policy_enabled`: (Optional) Manage the account-level SDP Static IP Allocation
  policy toggle. `null` (default) leaves the toggle unmanaged; `true`/`false`
  manages it via `cato_sdp_static_ip_allocation_policy`. SDP Static IP Allocation
  ships **disabled** on new tenants - set `policy_enabled = true` (or enable it
  in the CMA) for published rules to take effect.
- `allow_empty_policy`: (Optional) Safety guard - fail planning when the policy
  JSON contains 0 rules unless explicitly allowed. Default `false`.

## Working with Existing Rules (Brownfield Deployments)

For brownfield deployments where you have existing SDP Static IP Allocation
rules in your Cato Management Application, you can use the Cato CLI to export
and import these rules into Terraform state.

### Installing and Configuring Cato CLI

1. **Install the Cato CLI:**
   ```bash
   pip3 install catocli
   ```

2. **Configure the CLI with your Cato credentials:**
   ```bash
   catocli configure set
   ```
   This will prompt you for your Cato Management Application credentials and account information.

### Exporting Existing Rules

To export your existing SDP Static IP Allocation rules and sections into the JSON format required by this module:

```bash
catocli export ssia_rules --json-filename all_ssia_rules_and_sections.json
```

This command will generate a JSON file containing all your existing SSIA rules
and sections in the correct format for this Terraform module, rooted at
`data.policy.sdpStaticIpAllocation.policy` with `sections[]`, `rules[]`
(wrappers `{audit, rule, properties}`, ids retained for brownfield import), and
`rules_in_sections[]`.

### Importing Existing Rules into Terraform State

Once you have the JSON configuration file, you can adopt the existing rules
and sections into Terraform state. This is useful for:

- **Brownfield deployments**: Managing existing rules with Terraform
- **Backup and restore**: Restoring rules to a known good state after unintended changes
- **State management**: Bringing existing infrastructure under Terraform control

There are two ways to do this. Every `for_each` address in this module
(`rules_by_name`, `sections_data`) is keyed by name, exactly matching the
exported JSON's `rule.name` / `section_name` fields - that's why the import
blocks below line up one-to-one with the JSON with no re-keying.

<details>
<summary>Option A (recommended) - native Terraform import blocks (migration.tf)</summary>

Requires Terraform **>= 1.7**. Create a one-shot `migration.tf` file beside your module call:

```hcl
# migration.tf - one-time adoption of existing SDP Static IP Allocation rules/sections.
# Place beside the module call (same directory as main.tf), run once, then delete.

locals {
  ssia_migration_json     = jsondecode(file("${path.module}/config_data/all_ssia_rules_and_sections.json"))
  ssia_migration_policy   = local.ssia_migration_json.data.policy.sdpStaticIpAllocation.policy
  ssia_migration_sections = { for s in local.ssia_migration_policy.sections : s.section_name => s.section_id }
  ssia_migration_rules    = { for rw in local.ssia_migration_policy.rules : rw.rule.name => rw.rule.id }
}

import {
  for_each = local.ssia_migration_sections
  to       = module.ssia_rules.cato_sdp_static_ip_allocation_section.sections[each.key]
  id       = each.value
}

import {
  for_each = local.ssia_migration_rules
  to       = module.ssia_rules.cato_sdp_static_ip_allocation_rule.rules[each.key]
  id       = each.value
}
```

`cato_bulk_ssia_move_rule` is plan-time orchestration - it republishes the
whole policy on every apply and has no persisted object of its own to
import, so it never appears in `migration.tf`. Same for the optional
`cato_sdp_static_ip_allocation_policy` enable/disable toggle: it's a
tenant-wide singleton with no name/`for_each` to key an import block on.

Preview the adoption before anything touches state:

```bash
terraform plan
```

Expect `N to import, 0 to add, 0 to change, 0 to destroy`. Any non-zero "to
change" means the JSON export is stale relative to the live policy -
**re-export** (`catocli export ssia_rules`) and regenerate the locals above,
rather than letting `terraform apply` overwrite the live policy with stale
config.

Once the plan is clean, adopt the resources into state:

```bash
terraform apply
```

Then delete `migration.tf` - its job is done, and leaving it in place just
re-runs the same (no-op) import blocks on every future plan.

</details>

<details>
<summary>Option B - catocli import ssia_rules_to_tf (imperative alternative)</summary>

An imperative alternative to Option A, for when native import blocks aren't
practical (e.g. scripting a fully automated onboarding pipeline). Unlike
Option A, this mutates Terraform state immediately - there is no plan preview
before the import happens.

```bash
catocli import ssia_rules_to_tf config_data/all_ssia_rules_and_sections.json \
  --module-name module.ssia_rules --auto-approve
terraform plan   # expect: only cato_bulk_ssia_move_rule to add
```

**Parameters:**
- `config_data/all_ssia_rules_and_sections.json`: Path to your exported JSON file
- `--module-name module.ssia_rules`: The name of your Terraform module instance

</details>

### Typical Brownfield Workflow

1. **Export existing rules:**
   ```bash
   catocli export ssia_rules --json-filename all_ssia_rules_and_sections.json
   ```

2. **Create your Terraform configuration:**
   ```hcl
   module "ssia_rules" {
     source = "catonetworks/bulk-ssia-rules/cato"

     ssia_rules_json_file_path = "./config_data/all_ssia_rules_and_sections.json"
   }
   ```

3. **Adopt existing state (Option A - recommended):** create `migration.tf`
   with the import blocks shown above, then:
   ```bash
   terraform plan    # preview: expect only "to import"
   terraform apply   # adopt into state
   ```
   Delete `migration.tf` afterwards. (Option B: `catocli import
   ssia_rules_to_tf config_data/all_ssia_rules_and_sections.json --module-name
   module.ssia_rules` - imperative, no plan preview.)

4. **Run Terraform plan to verify:**
   ```bash
   terraform plan
   ```
   This should show no changes if the import was successful.

### Backup and Restore Workflow

If unintended changes are made directly to rules and sections in the Cato
Management Application, you can restore to the last known good state:

1. **Apply your last known good configuration:**
   ```bash
   terraform apply
   ```
   This will restore rules and sections to match your Terraform configuration.

2. **Alternatively, re-export and compare:**
   ```bash
   catocli export ssia_rules --json-filename all_ssia_rules_and_sections.json
   # Compare with your existing JSON file to identify changes
   ```

## Known Limitations

- Ordering rows with `section_name: ""` are excluded from the move resource
  and surfaced via `unordered_rules`; their order is creation order.
- Run applies with `-parallelism=1` when several module instances share an
  account.
- Only `cato_sdp_static_ip_allocation_rule`/`cato_sdp_static_ip_allocation_section`
  support import; `cato_bulk_ssia_move_rule` and the
  `cato_sdp_static_ip_allocation_policy` toggle are outside the JSON-driven
  import flow (see above).

## Using Module Outputs

The module provides outputs that can be used for monitoring, auditing,
integration with other systems, and operational insights. Below are practical
examples of how to use these outputs in your Terraform configuration.

<details>
<summary>Click to expand example client-side outputs</summary>

```hcl
# Basic deployment information
output "deployment_info" {
  description = "Basic information about the SDP Static IP Allocation deployment"
  value = {
    sections = module.ssia_rules.deployment_summary.sections
    rules    = module.ssia_rules.deployment_summary.rules
  }
}

# Quick reference for rule and section IDs
output "quick_reference" {
  description = "Quick reference maps for rules and sections"
  value = {
    section_ids = module.ssia_rules.section_ids
    rule_ids    = module.ssia_rules.rule_ids
  }
}

# Rows that could not be placed in the ordering resource
output "ordering_gaps" {
  description = "rules_in_sections rows excluded from cato_bulk_ssia_move_rule"
  value       = module.ssia_rules.unordered_rules
}

# Example: For audit and compliance reporting
output "audit_report" {
  description = "Example audit report using module outputs"
  value = {
    date               = timestamp()
    sections_deployed  = module.ssia_rules.deployment_summary.sections
    rules_deployed     = module.ssia_rules.deployment_summary.rules
    section_ids        = module.ssia_rules.section_ids
    rule_ids           = module.ssia_rules.rule_ids
    unordered_rules    = module.ssia_rules.unordered_rules
  }
}
```
</details>

### Output Use Cases

These example outputs demonstrate various practical applications:

- **`deployment_info`**: Quick deployment overview for dashboards
- **`quick_reference`**: ID mappings for referencing resources in other modules
- **`ordering_gaps`**: Visibility into sectionless rules whose order is
  creation-order best-effort only
- **`audit_report`**: Comprehensive audit trail for compliance

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.5.0 |
| <a name="requirement_cato"></a> [cato](#requirement\_cato) | >= 1.3.1 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_cato"></a> [cato](#provider\_cato) | >= 1.3.1 |
| <a name="provider_terraform"></a> [terraform](#provider\_terraform) | n/a |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [cato_bulk_ssia_move_rule.all_ssia_rules](https://registry.terraform.io/providers/catonetworks/cato/latest/docs/resources/bulk_ssia_move_rule) | resource |
| [cato_sdp_static_ip_allocation_policy.policy](https://registry.terraform.io/providers/catonetworks/cato/latest/docs/resources/sdp_static_ip_allocation_policy) | resource |
| [cato_sdp_static_ip_allocation_rule.rules](https://registry.terraform.io/providers/catonetworks/cato/latest/docs/resources/sdp_static_ip_allocation_rule) | resource |
| [cato_sdp_static_ip_allocation_section.sections](https://registry.terraform.io/providers/catonetworks/cato/latest/docs/resources/sdp_static_ip_allocation_section) | resource |
| [terraform_data.guard_empty_policy](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_allow_empty_policy"></a> [allow\_empty\_policy](#input\_allow\_empty\_policy) | Safety guard: fail planning when the policy JSON contains 0 rules unless explicitly allowed. Protects against a truncated or wrong-tenant export destroying the live policy. Set true only for intentional greenfield/teardown. | `bool` | `false` | no |
| <a name="input_policy_enabled"></a> [policy\_enabled](#input\_policy\_enabled) | Manage the account-level SDP Static IP Allocation policy toggle. null leaves the toggle unmanaged; true/false manages it via cato\_sdp\_static\_ip\_allocation\_policy. | `bool` | `null` | no |
| <a name="input_ssia_rules_json_file_path"></a> [ssia\_rules\_json\_file\_path](#input\_ssia\_rules\_json\_file\_path) | Path to the SDP Static IP Allocation JSON export produced by `catocli export ssia_rules` (data.policy.sdpStaticIpAllocation.policy root). | `string` | n/a | yes |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_deployment_summary"></a> [deployment\_summary](#output\_deployment\_summary) | Counts of managed SDP Static IP Allocation objects. |
| <a name="output_rule_ids"></a> [rule\_ids](#output\_rule\_ids) | Map of rule name to rule id. |
| <a name="output_section_ids"></a> [section\_ids](#output\_section\_ids) | Map of section name to section id. |
| <a name="output_unordered_rules"></a> [unordered\_rules](#output\_unordered\_rules) | rules\_in\_sections rows excluded from cato\_bulk\_ssia\_move\_rule (no managed section to order within). |
<!-- END_TF_DOCS -->
