# Creating the `gemini-api` Secret

Run on a machine where `kubectl` works (add `sudo k3s` in front on a K3s node). The key is typed or pasted without being shown, and never reaches the shell history or a process argument:

```bash
( umask 077
  d=$(mktemp -d -p /dev/shm)
  printf 'Gemini API key: ' ; read -rs key ; echo
  printf '%s' "$key" > "${d:?}/api-key" ; unset key
  kubectl -n agents create secret generic gemini-api --from-file="${d:?}"
  rm -rf "${d:?}" )
kubectl -n agents describe secret gemini-api     # shows the key name and its size only
```

The agent container receives the key as the environment variable `GEMINI_API_KEY`. The agent can read it; the network policy limits where it can be sent (see the threat model).
