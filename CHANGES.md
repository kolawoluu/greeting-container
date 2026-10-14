# Container changes

## What I changed

| Change                                                                                                          | Why I made it                                                                                                                                                                                                                                                         | Trade-off                                                                                                                                       |
| --------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| I switched from the pinned full `python:3.12` image to `python:3.12-slim`, pinned by digest in both stages.     | I kept Python 3.12 and made the base image repeatable while starting from a smaller image.                                                                                                                                                                            | I need to update the digest deliberately. Slim is still larger than Alpine or distroless.                                                       |
| I removed `build-essential`, `gcc`, `curl`, and `vim` from the runtime image.                                   | The app does not need these tools to run, so leaving them out reduces image contents and attack surface.                                                                                                                                                              | I cannot use those tools interactively inside the runtime container. If a dependency needs a compiler, I should add it to the build stage only. |
| I used a build stage for dependency installation and copied its virtual environment into a clean runtime stage. | This keeps build-stage files and tools out of the final image. It also gives me a place to compile dependencies if that becomes necessary.                                                                                                                            | Both stages need compatible Python versions, and the virtual environment still contributes to the final image size.                             |
| I copied `requirements.txt` before the application code and used `pip --no-cache-dir`.                          | A code-only change can reuse the dependency-install layer, and pip does not leave its download cache in that layer.                                                                                                                                                   | Flask and Gunicorn are pinned directly, but their transitive dependencies are not locked or hash-checked.                                       |
| I added a `.dockerignore` allow-list.                                                                           | Only `app/app.py`, `app/requirements.txt`, and `gunicorn.conf.py` enter the Docker build context.                                                                                                                                                                     | If I later need another file in the image, I must explicitly allow it in `.dockerignore`.                                                       |
| I created UID/GID `10001` and run the app as that user. I copy the app and Gunicorn config without `--chown`.   | Gunicorn does not run as root, and the app user cannot modify its code or config.                                                                                                                                                                                     | If the app needs to write data later, I will need to provide a writable location, such as a volume.                                             |
| I added `gunicorn.conf.py`.                                                                                     | It makes Gunicorn bind to `PORT`, puts worker temporary files in `/dev/shm`, and sends request logs to stdout so I can inspect them with `docker logs` or `kubectl logs`. I verified that the `/dev/shm` setting lets the image run with a read-only root filesystem. | Request logging adds one log line per request, which can increase log volume.                                                                   |
| I added a Docker `HEALTHCHECK` for `/healthz`.                                                                  | Docker-compatible runtimes can report whether the app responds to its health endpoint.                                                                                                                                                                                | Kubernetes uses probes from the Pod spec instead, so I will need to configure those separately.                                                 |
| I added OCI source, license, and version labels, with `VERSION` as a build argument.                            | I can include version metadata when I build without editing the Dockerfile.                                                                                                                                                                                           | The default version is `dev`. The argument sets an image label, not the registry tag.                                                           |

## Measurements

I built both images for `linux/amd64` on my ARM Mac. I took these measurements on 2026-10-13 using Trivy 0.56.2, Hadolint 2.14.0, and Proofctl 0.6.0. I ran Trivy with `--severity CRITICAL,HIGH` and without `--ignore-unfixed`, so its counts include fixed and unfixed findings. Image sizes and build-context sizes are the values reported by Docker and BuildKit.

| Measure                   | Original (`upstream/main`)                                                                                                                         | My version                                                                                       | How I checked                                                                                                                            |
| ------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------- |
| Image size                | 1.19 GB (1,193,246,230 bytes)                                                                                                                      | 137 MB (136,970,534 bytes), 88.5% smaller                                                        | `docker image inspect`                                                                                                                   |
| CRITICAL/HIGH CVEs        | 16 CRITICAL, 409 HIGH                                                                                                                              | 0 CRITICAL, 44 HIGH                                                                              | Same Trivy version and database, with `--severity CRITICAL,HIGH`. I did not exclude unfixed findings.                                    |
| Hadolint findings         | 4 total, 2 warnings and 2 informational                                                                                                            | 0                                                                                                | Hadolint 2.14.0 on both Dockerfiles                                                                                                      |
| Proofctl findings         | 7 total, 1 warning and 6 informational. The warning was that the container ran as root.                                                            | 0                                                                                                | Proofctl 0.6.0 with `--no-pypi` on both repository snapshots                                                                             |
| Runtime user              | Root, because the original Dockerfile had no `USER` instruction                                                                                    | `uid=10001(app) gid=10001(app)`                                                                  | Ran each image with `--entrypoint id`                                                                                                    |
| Code-only rebuild         | The original `COPY . .` comes before dependency installation, so changing app code invalidates the install layer. I did not time this baseline.    | 0.19 seconds for a warm code-only rebuild. The install step was cached.                          | Changed only `app/app.py` in a temporary copy and checked the BuildKit output. This was a warm local build, not a clean-build benchmark. |
| Build context transferred | 6.52 kB                                                                                                                                            | 278 B                                                                                            | BuildKit output                                                                                                                          |
| Honors `PORT`             | No. The original Gunicorn command binds to `0.0.0.0:8080`.                                                                                         | Yes. With `PORT=9090`, `/healthz` returned 200.                                                  | Ran on mapped port 9090 and requested `/healthz`                                                                                         |
| Docker health check       | Not configured                                                                                                                                     | Docker reported `healthy`; `/healthz` returned `{"status":"ok"}`                                 | Inspected the container after startup                                                                                                    |
| Read-only root filesystem | Failed with `FileNotFoundError: No usable temporary directory found`; Gunicorn's default temporary directory was on the read-only root filesystem. | Passed with `--read-only --cap-drop ALL` and no extra `/dev/shm` mount. `/healthz` returned 200. | Ran both images with a read-only root. For mine, I also dropped all capabilities and enabled `no-new-privileges`.                        |
| Graceful stop             | 0.27 seconds. Gunicorn handled `SIGTERM` and shut down cleanly.                                                                                    | 0.33 seconds. Gunicorn handled `SIGTERM` and shut down cleanly.                                  | Timed `docker stop -t 30` after giving each container 3 seconds to start                                                                 |

Both local images reported `linux/amd64`. I have not checked a published GHCR package, its visibility, or its manifest. I will verify Kubernetes `/dev/shm` behavior in the cluster during Part 2.

## How I test the image

I build locally for the target cluster architecture. This command does not publish the image:

```sh
docker buildx build \
  --platform linux/amd64 \
  --build-arg VERSION=test \
  --load \
  -t sample-app:test .
```

I check the configured command, runtime user, and ownership of the app files:

```sh
docker image inspect sample-app:test \
  --format 'User={{.Config.User}} Cmd={{json .Config.Cmd}}'
docker run --rm --entrypoint id sample-app:test
docker run --rm --entrypoint stat sample-app:test \
  -c '%u:%g %n' /app/app.py /app/gunicorn.conf.py
```

I start the container, give Gunicorn a moment to start, and request the app endpoints:

```sh
docker run -d --name sample-app -p 8080:8080 sample-app:test
sleep 3
curl -fsS http://127.0.0.1:8080/
curl -fsS http://127.0.0.1:8080/healthz
curl -fsS http://127.0.0.1:8080/info
time docker stop -t 30 sample-app
docker logs sample-app
docker rm sample-app
```

I check that the app honors a different port:

```sh
docker run -d --name sample-app-port \
  -e PORT=9090 -p 9090:9090 sample-app:test
sleep 3
curl -fsS http://127.0.0.1:9090/
docker stop -t 30 sample-app-port
docker rm sample-app-port
```

I check that it runs with a read-only root filesystem and all Linux capabilities dropped. The container runtime provides `/dev/shm`; I do not need to mount it explicitly for this test.

```sh
docker run -d --name sample-app-restricted \
  --read-only \
  --cap-drop ALL \
  --security-opt no-new-privileges \
  -p 8080:8080 \
  sample-app:test
sleep 3
curl -fsS http://127.0.0.1:8080/healthz
docker stop -t 30 sample-app-restricted
docker rm sample-app-restricted
```

These examples reuse host ports `8080` and `9090`. I stop and remove each container before starting another on the same port.

After publishing the image, I checked that it could be pulled without GHCR credentials and inspected the manifest:

```sh
docker pull ghcr.io/kolawoluu/sample-app:v1
docker buildx imagetools inspect ghcr.io/kolawoluu/sample-app:v1
```

The anonymous pull succeeded. The manifest digest was `sha256:0131135470a1d5c2526131386dcce559f9706a4441b06034de0782a4d35e2a08` and listed both `linux/amd64` and `linux/arm64`.

`VERSION` sets image metadata; it does not create or move the image tag.

## Continuous integration

The GitHub Actions workflow runs on pull requests and pushes to `main`. It lints the Dockerfile and Markdown, scans the repository with Proofctl, builds and scans both the `linux/amd64` and `linux/arm64` images with Trivy, and smoke-tests both images with a read-only root filesystem and all capabilities dropped. HIGH Trivy findings are reported; CRITICAL findings fail the workflow. It does not publish the image.

## What I left out

-   **A transitive lock file and hash-checked install:** I left `app/requirements.txt` unchanged as requested. I would need to generate and maintain a separate lock or constraints file to pin transitive dependencies.
-   **Distroless:** I kept the Python slim image because it is simpler to inspect and troubleshoot for this small Flask and Gunicorn app.
-   **A Python version upgrade:** I kept Python 3.12 and avoided changing the app's runtime version as part of this task.
-   **A Kubernetes manifest:** This part asks to containerize the app. The Kubernetes deployment will be done later.
