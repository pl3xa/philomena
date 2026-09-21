# Philomena

![Philomena](/assets/static/images/phoenix.svg)

## Getting Started

Make sure you have [Docker](https://docs.docker.com/engine/install/) and [Docker Compose plugin](https://docs.docker.com/compose/install/#scenario-two-install-the-docker-compose-plugin) installed.

Add the directory `scripts/path` to your `PATH` to get the `philomena` dev CLI globally available in your terminal. For example you can add the following to your shell's `.*rc` file, but adjust the path to philomena repo accordingly.

```bash
export PATH="$PATH:$HOME/dev/philomena/scripts/path"
```

Use the following commands to bring up or shut down a dev server.

```bash
philomena up
philomena down
```

Once the application has started, navigate to http://localhost:8080 and login with

| Credential | Value               |
| ---------- | ------------------- |
| Email      | `admin@example.com` |
| Password   | `philomena123`      |

> [!TIP]
> See the source code of `scripts/philomena.sh` for details on the additional parameters and other subcommands.

## Pre-commit hook

Run the following command to configure the git pre-commit hook that will auto-format the code and run lightweight checks on each commit.

```bash
philomena init
```

## IDE Setup

If you are using VSCode, you are encouraged to install the recommended extensions that VSCode should automatically suggest to you based on `.vscode/extensions.json` file in this repo.

## Troubleshooting

If you are running Docker on Windows and the application crashes immediately upon startup, please ensure that `autocrlf` is set to `false` in your Git config, and then re-clone the repository. Additionally, it is recommended that you allocate at least 4GB of RAM to your Docker VM.

If you run into an OpenSearch bootstrap error, you may need to increase your `max_map_count` on the host as follows:

```
sudo sysctl -w vm.max_map_count=262144
```

If you have SELinux enforcing (Fedora, Arch, others; manifests as a `Could not find a Mix.Project` error), you should run the following in the application directory on the host before proceeding:

```
chcon -Rt svirt_sandbox_file_t .
```

This allows Docker or Podman to bind mount the application directory into the containers.

If you are using a platform which uses cgroups v2 by default (Fedora 31+), use `podman` and `podman-compose`.

## Deployment

You need a key installed on the server you target, and the git remote installed in your ssh configuration.

    git remote add production philomena@<serverip>:philomena/

The general syntax is:

    git push production master

And if everything goes wrong:

    git reset HEAD^ --hard
    git push -f production master

(to be repeated until it works again)

## Derpibooru tag imports

Image pages offer reverse lookup or a manual Derpibooru ID to signed-in metadata
editors. Reverse lookup creates the same one-hour temporary share as the timer
button. Each candidate previews local tag additions, including aliases,
implications, and locked-tag rules. Merging preserves existing tags and writes an
approved audit comment as `system`, naming the initiating user and source image.
Conflicting rating tags must be resolved manually before merging. Previews expire
after 15 minutes; changed additions require another review.

Set `DERPIBOORU_API_KEY` in the existing 1Password Environment, run `bin/sync-env`,
and recreate the app container to load it. Never put its value in tracked files.
The account named `system` must already exist; it does not require staff privileges.
`DERPIBOORU_SYSTEM_USER` can override that name when supplied to the app environment.
The feature is disabled without an API key and refuses writes without the audit
account. API credentials stay on the server. Lookups are throttled and cached
briefly, and local sharing-control tags are excluded from imports.

A one-time bulk sweep can be started with
`mix derpibooru.sweep /persistent/path/state.json`. It freezes the current maximum
image ID and resumes from that file; a completed checkpoint never starts a second
sweep. Requests are spaced at least ten seconds apart, retry with exponential
backoff (up to ten minutes), and respect upstream retry delays. Six failed attempts
record that image as failed and continue, preserving the backoff across images.
Hidden/deleted images and images the system user cannot edit are recorded as skips.
Only a single reverse-search candidate with width and height within 10% and aspect
ratio within 2% can merge. Normal tag validation still applies. Both tag history
and the audit comment are attributed to `system`. Per-image outcomes are appended
to `state.json.jsonl`; create `state.json.stop` to pause after the current image.
