# terraform-cato-bulk-ssia-rules
#
# Bulk-manages the Cato SDP Static IP Allocation (sdpStaticIpAllocation) policy from one JSON
# export produced by `catocli export ssia_rules`:
#   sections[] / rules[] / rules_in_sections[] - flat policy, no sub-policies.
# cato_bulk_ssia_move_rule applies ordering and republishes.
# Rule fields: ip (static IP), source.user (single user ref).

locals {
  ssia_json = jsondecode(file("${var.ssia_rules_json_file_path}"))
  ssia      = local.ssia_json.data.policy.sdpStaticIpAllocation.policy

  sections_data_raw      = try(local.ssia.sections, [])
  rules_data_raw         = try(local.ssia.rules, [])
  rules_in_sections_data = try(local.ssia.rules_in_sections, [])

  sections_data = {
    for s in local.sections_data_raw : s.section_name => s
  }

  rules_by_name = {
    for rw in local.rules_data_raw : rw.rule.name => rw
  }

  move_section_data = {
    for name, s in local.sections_data : name => {
      section_index = s.section_index
    }
  }

  move_rule_data = {
    for row in local.rules_in_sections_data :
    row.rule_name => {
      index_in_section = row.index_in_section
      section_name     = row.section_name
    }
    if row.section_name != "" && contains(keys(local.sections_data), row.section_name)
  }

  unordered_rules_data = [
    for row in local.rules_in_sections_data : row
    if !contains(keys(local.move_rule_data), try(row.rule_name, ""))
  ]

  rule_bodies = {
    for name, rw in local.rules_by_name : name => merge(
      {
        name    = rw.rule.name
        enabled = try(rw.rule.enabled, true)
        ip      = rw.rule.ip
        source = {
          user = can(rw.rule.source.user.name) ? { name = rw.rule.source.user.name } : { id = rw.rule.source.user.id }
        }
      },
      try(rw.rule.description, "") != "" ? { description = rw.rule.description } : {}
    )
  }
}

# Safety guard: fail planning early if the decoded policy JSON has 0 rules, unless
# the caller opts in via allow_empty_policy. Protects against a truncated export,
# a renamed upstream JSON key, or a wrong-tenant export silently destroying every
# live rule. No provider, no count/for_each - always evaluated.
resource "terraform_data" "guard_empty_policy" {
  lifecycle {
    precondition {
      condition     = var.allow_empty_policy || length(local.rules_by_name) > 0
      error_message = "Policy JSON contains 0 rules. If intentional (greenfield/teardown), set allow_empty_policy = true. A truncated or wrong-tenant export would otherwise destroy the entire live policy."
    }
  }
}

# Optional account-level policy toggle (SDP Static IP Allocation ships disabled on new
# tenants - without enabling it, published rules have no effect).
resource "cato_sdp_static_ip_allocation_policy" "policy" {
  count   = var.policy_enabled == null ? 0 : 1
  enabled = var.policy_enabled
}

resource "cato_sdp_static_ip_allocation_section" "sections" {
  for_each = local.sections_data
  at = {
    position = "LAST_IN_POLICY"
  }
  section = {
    name = each.value.section_name
  }
}

resource "cato_sdp_static_ip_allocation_rule" "rules" {
  depends_on = [cato_sdp_static_ip_allocation_section.sections]
  for_each   = local.rules_by_name

  at = contains(keys(local.sections_data), each.value.rule.section.name) ? {
    position = "LAST_IN_SECTION"
    ref      = cato_sdp_static_ip_allocation_section.sections[each.value.rule.section.name].id
    } : {
    position = "LAST_IN_POLICY"
  }

  rule = local.rule_bodies[each.key]
}

# Ordering + republish on changes.
resource "cato_bulk_ssia_move_rule" "all_ssia_rules" {
  depends_on = [cato_sdp_static_ip_allocation_section.sections, cato_sdp_static_ip_allocation_rule.rules]

  section_data = local.move_section_data
  rule_data    = local.move_rule_data
}
