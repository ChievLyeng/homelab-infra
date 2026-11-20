FROM python:3.12-slim

# openssh-client: Ansible connects to the VMs over SSH.
RUN apt-get update \
    && apt-get install -y --no-install-recommends openssh-client git \
    && rm -rf /var/lib/apt/lists/*

# Pinned tool versions (see requirements.txt) so every machine and CI run behaves the same.
COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt

# Ansible collections used by the roles.
COPY requirements.yml /tmp/requirements.yml
RUN ansible-galaxy collection install -r /tmp/requirements.yml -p /usr/share/ansible/collections

# The repo is mounted at /work at run time (see the Makefile).
WORKDIR /work/ansible
