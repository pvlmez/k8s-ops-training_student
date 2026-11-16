# Lab 8: a Vault policy. It allows reading the secrets below secret/lab8/
# and nothing else: no writing, no listing, no other paths.
#
# The path says "secret/data/lab8/..." although you write "secret/lab8/..."
# on the command line: in the KV version 2 engine the values live under data/.
path "secret/data/lab8/*" {
  capabilities = ["read"]
}
