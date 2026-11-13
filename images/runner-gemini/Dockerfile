# Gemini runner image: Node, the Gemini CLI at a fixed version, and the small wrapper that runs one task.
# No credentials are baked in. The API key arrives as an environment variable from a Secret at run time;
# the Redis password never reaches this container at all (see manifests/40-runner-gemini.yaml).
FROM node:24.16.0-alpine3.22@sha256:191c9f0080fcbbc6547a85dc0ff7988072214a355aabdc1d2ec55a7dae5eea8a

RUN npm install -g --no-fund --no-audit @google/gemini-cli@0.68.0 \
 && npm cache clean --force

# System-wide CLI settings: no usage statistics, no telemetry, no automatic update check.
COPY settings.json /etc/gemini-cli/settings.json
COPY run-task.mjs /usr/local/bin/run-task.mjs

USER 1000:1000
WORKDIR /workspace
ENTRYPOINT ["node", "/usr/local/bin/run-task.mjs"]
