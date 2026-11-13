# Creating the `redis-auth` Secret

Random passwords for the Redis users `admin` and `keda` (the key `runner` belongs to an earlier version and is no longer used; creating it does no harm). Run this on a machine where `kubectl` works (add `sudo k3s` in front of `kubectl` on a K3s node):

```bash
( umask 077
  d=$(mktemp -d -p /dev/shm)
  for k in admin keda runner; do openssl rand -hex 24 | tr -d '\n' > "${d:?}/$k"; done
  kubectl -n agents create secret generic redis-auth --from-file="${d:?}"
  rm -rf "${d:?}" )
```

Why this form and not `--from-literal=admin="$(openssl rand -hex 24)"`:

- `--from-literal` puts the password into the arguments of the `kubectl` process. Anything that records process arguments (`ps`, audit tools, Tetragon) can keep it.
- Here the passwords are written to files in memory (`/dev/shm`), in a directory only you can read, and removed right after. Nothing is printed and nothing reaches the shell history.
- `tr -d '\n'` matters: `--from-file` stores the file as it is, and a trailing newline would become part of the password.

Check that it worked, without showing a value:

```bash
kubectl -n agents describe secret redis-auth
```

`describe` prints key names and sizes only. Each of `admin`, `keda`, `runner` should say `48 bytes`; 49 would mean a newline slipped in.

## The other Redis Secrets

Same pattern, one password per key:

```bash
( umask 077
  d=$(mktemp -d -p /dev/shm)
  for k in gemini claude; do openssl rand -hex 24 | tr -d '\n' > "${d:?}/$k"; done
  kubectl -n agents create secret generic redis-runners --from-file="${d:?}"
  rm -rf "${d:?}" )

( umask 077
  d=$(mktemp -d -p /dev/shm)
  openssl rand -hex 24 | tr -d '\n' > "${d:?}/password"
  kubectl -n agents create secret generic redis-fetcher --from-file="${d:?}"
  rm -rf "${d:?}" )
```

Redis reads all of them at start, so create them before applying `manifests/10-redis.yaml`; a missing one keeps the Redis pod from starting.
