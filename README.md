# kubernetes2simple

*Kubernetes? Too simple.*

You have a Kubernetes project. You want to run it locally with `docker compose`. You don't want to think about it.

```bash
curl -fsSL https://raw.githubusercontent.com/dekubeio/kubernetes2simple/main/kubernetes2simple.sh -o k2s.sh
chmod +x k2s.sh
./k2s.sh
docker compose up -d
```

The script looks at your project, figures out what it is, installs whatever tools are missing, and produces a working `docker compose` setup. Everything it downloads lives in `.kubernetes2simple/` — your system stays clean.

## What you need

- Docker (with `docker compose`)
- Python 3.10+

That's all. The rest is handled.

## Options

```
./k2s.sh [--env <environment>] [--output-dir <dir>] [--clean]
```

`--env` selects a helmfile environment if your project uses one. `--clean` wipes the local cache and starts fresh.

## Good to know

The script generates three files: `compose.yml`, `Caddyfile`, and `dekube.yaml`.

**You can re-run it safely.** Your `compose.yml` and `Caddyfile` are regenerated every time — don't edit them by hand, your changes will be overwritten. If you need to customize something (exclude a service, override an image, pin a volume path), edit `dekube.yaml` instead. That file is yours — the script reads it but never overwrites it.

**TLS is best-effort.** If your project uses cert-manager certificates, the script generates self-signed certs locally so things can start. This is fine for development. It is not a replacement for your actual certificate setup — don't ship this to production expecting real TLS.

**Some things won't convert.** CronJobs, resource limits, probes, HPA — anything that doesn't have a compose equivalent is skipped with a warning. This is expected. The goal is a working local environment, not a 1:1 replica of your cluster.

## It didn't work

[Open an issue.](https://github.com/dekubeio/kubernetes2simple/issues) Describe what you pointed it at, paste the output. We'll figure it out.

*Just don't ask how it works.*

---

<details>
<summary>You want answers? Click at your own risk.</summary>

<br>

kubernetes2simple is the turnkey face of [dekube](https://dekube.io) — an heretical, overengineered conversion engine that parses Kubernetes manifests, resolves ConfigMaps and Secrets, rewrites Service DNS, generates TLS certificates, produces reverse proxy configurations, and reassembles the whole thing as `docker compose` services. It has an extension system, a package manager, a fake API server for the things that can't be faked, a regression test suite with an O(n³) torture generator, and documentation written in the tone of forbidden texts.

It was not designed. It was revealed, one mass-produced horror at a time, across increasingly unhinged AI-assisted sessions. The Lovecraftian quotes in the docs started as a joke. They stopped being funny around the third project.

kubernetes2simple bundles the engine, all official extensions, and a bootstrap script into a single command so you never have to see any of this. You're welcome.

[Full documentation](https://docs.dekube.io) · [Source engine](https://github.com/dekubeio/dekube-engine) · [Extension registry](https://github.com/dekubeio/dekube-manager)

</details>
