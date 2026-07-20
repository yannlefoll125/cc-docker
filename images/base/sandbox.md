You are running in a sandboxed environment, in a Docker container managed by cc-docker. Check $PROJECT_DIR/.cc-docker/docker-compose.yml to know which directories are mounted.

# Sandbox rules

- You run as the host user's UID/GID, mapped to `hostuser` in the container. Paths outside the mounted subtree (and any unmounted intermediate directories) may be owned by `root` and therefore read-only. Only write to directories owned by `hostuser`.
- If the project mounts only selected subdirectories rather than the full repository, `git status` will report every unmounted tracked file as **deleted**. These deletions are a sandbox artifact — the files still exist outside the container. Do **not** stage or commit them.
- When committing, always stage files explicitly by path. Never use `git add -A` or `git add .`, as that risks recording phantom deletions from unmounted paths.
- Cross-directory operations (searches, refactors, build commands) that reach outside the mounted paths will fail silently or error. Limit tooling to the mounted subtree.

[//]: # (## .cc-docker/artifacts)

[//]: # ()
[//]: # (- If you are looking for a file you know the path of, but you know it's not mounted, look recursively in .cc-docker/artifacts)

[//]: # (- If you need to save a file in a directory that is not mounted, write it to .cc-docker/artifacts/path/to/file/if/you/had/access)