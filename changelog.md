# Changelog

## 0.0.1 (2026-11-04)

- Initial release: bulk management of SDP Static IP Allocation rules & sections from a catocli JSON export, name-keyed state addressing.
- `allow_empty_policy` safety guard — planning fails on a 0-rule JSON unless explicitly allowed, protecting against truncated or wrong-tenant exports.
- README documents two brownfield-import options: native Terraform `import` blocks (recommended) and the `catocli import ssia_rules_to_tf` CLI alternative.
