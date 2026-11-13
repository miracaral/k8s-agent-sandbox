# Fetcher image: git and redis-cli on Alpine. It clones a public repository and hands it to the agent
# through Redis. It holds no GitHub credential; its only secret is its own Redis password.
FROM alpine:3.22.8@sha256:49340b346798875b5592e5d420241f2f9cfba5f47e62ebb1446a1b34734e898f
RUN apk add --no-cache git=2.49.1-r0 redis=8.0.4-r0 \
 && git --version && redis-cli --version
USER 1000:1000
