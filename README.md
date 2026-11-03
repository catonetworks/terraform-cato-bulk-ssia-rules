# terraform-cato-bulk-ssia-rules

Bulk-manages the Cato **SDP Static IP Allocation (sdpStaticIpAllocation)** policy from a single
JSON export: sections and rules (flat policy - no sub-policies exist for this
type), with ordering and publishing via `cato_bulk_ssia_move_rule`.

## Resources managed

| Resource | Keyed by | Notes |
|---|---|---|
| `cato_sdp_static_ip_allocation_section.sections` | `section_name` | created `LAST_IN_POLICY`; ordered by the move resource |
| `cato_sdp_static_ip_allocation_rule.rules` | rule name | placement: managed section -> `LAST_IN_SECTION`; sectionless -> `LAST_IN_POLICY` |
| `cato_bulk_ssia_move_rule.all_ssia_rules` | - | orders sections (`section_index`) and rules (`index_in_section`) and **publishes** |
| `cato_sdp_static_ip_allocation_policy.policy` | - | optional account-level enable/disable toggle (`policy_enabled` variable) |

**Publishing:** the rule/section resources save to the draft policy only -
`cato_bulk_ssia_move_rule` is this stack's single publisher. Without it, applies never
go live. SDP Static IP Allocation ships **disabled** on new tenants - set
`policy_enabled = true` (or enable it in the CMA) for published rules to
take effect.

## Input JSON

```bash
catocli export ssia_rules --json-filename all_ssia_rules_and_sections.json
```

Root: `data.policy.sdpStaticIpAllocation.policy` with `sections[]`, `rules[]`
(wrappers `{audit, rule, properties}`, ids retained for brownfield import),
and `rules_in_sections[]`. Rule fields: ip (static IP), source.user (single user ref).

## Usage

```hcl
module "ssia_rules" {
  source                   = "catonetworks/bulk-ssia-rules/cato"
  ssia_rules_json_file_path = "${path.module}/config_data/all_ssia_rules_and_sections.json"
}
```

## Brownfield import

```bash
catocli import ssia_rules_to_tf config_data/all_ssia_rules_and_sections.json \
  --module-name module.ssia_rules --auto-approve
terraform plan   # expect: only cato_bulk_ssia_move_rule to add
```

## Known limitations

- Ordering rows with `section_name: ""` are excluded from the move resource
  and surfaced via `unordered_rules`; their order is creation order.
- Run applies with `-parallelism=1` when several module instances share an
  account.
