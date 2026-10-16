FROM ubuntu:22.04 as uta

# list and install dependencies
# build-essential is needed to compile uta-align, which has no wheels
ARG dependencies="build-essential curl ca-certificates rsync git postgresql-client-14 tabix"

RUN apt-get update && apt-get install -y $dependencies && apt-get clean

# install uv; it downloads the Python version in .python-version and installs
# the locked dependencies into a virtual environment
COPY --from=ghcr.io/astral-sh/uv:0.12.19 /uv /uvx /bin/

# Where uv stores the Python it downloads. The default is under the home
# directory of the user running uv (root), which the non-root uta-tester user
# in the test image could not read; the venv's python is a symlink into here.
ENV UV_PYTHON_INSTALL_DIR=/opt/python

# Where `uv sync` creates the virtual environment, instead of .venv in the
# project directory. docker-compose.yml bind-mounts the repo over
# /opt/repos/uta, which would hide a project-local .venv.
ENV UV_PROJECT_ENVIRONMENT=/opt/venv

# Copy packages into the venv instead of hardlinking them from uv's cache.
# The cache and the venv can sit on different filesystems during a build, and
# hardlinking then fails or warns.
ENV UV_LINK_MODE=copy

# Put the venv first on PATH so that `python`, `uta`, `alembic`, `seqrepo`, and
# the `#!/usr/bin/env python` scripts in sbin/ all use it.
ENV PATH="/opt/venv/bin:${PATH}"

WORKDIR /opt/repos/uta/
COPY .python-version pyproject.toml uv.lock README.md ./
COPY etc ./etc
COPY misc ./misc
COPY sbin ./sbin
COPY src ./src
RUN uv sync --frozen --no-dev


# UTA test image
FROM uta as uta-test
RUN DEBIAN_FRONTEND=noninteractive apt-get -yq install postgresql
COPY tests ./tests
RUN uv sync --frozen --no-dev --extra test
RUN useradd uta-tester
RUN chown -R uta-tester .
USER uta-tester
