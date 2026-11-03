variable "ssia_rules_json_file_path" {
  description = "Path to the SDP Static IP Allocation JSON export produced by `catocli export ssia_rules` (data.policy.sdpStaticIpAllocation.policy root)."
  type        = string
}

variable "policy_enabled" {
  description = "Manage the account-level SDP Static IP Allocation policy toggle. null leaves the toggle unmanaged; true/false manages it via cato_sdp_static_ip_allocation_policy."
  type        = bool
  default     = null
}
