# Built-in ruleset only; it ships inside the tflint binary, so no
# `tflint --init` and no plugin download.
plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

# Inherited: dev/variables.tf declares project, environment and n8n_ip
# but nothing references them. Deleting them could leave dev.tfvars
# (gitignored, unreadable here) setting undeclared variables, so they
# stay until someone can check that file.
rule "terraform_unused_declarations" {
  enabled = false
}
