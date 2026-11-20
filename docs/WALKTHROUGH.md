# Walkthrough: how this cluster was built, step by step

Read [GUIDE.md](GUIDE.md) first for the concepts. This document follows the real work in the
order it happened. For every step it says **which command you ran, which tool it started
(Terraform or Ansible), which file did the work, and what changed**. Keep the code open next
to this document and read them together.

File references look like `terraform/envs/prod/main.tf:20`: the file, then the line number.
Line numbers can drift when files change, so search for the nearby text if a line is off.

---

## 0. The one-page map

### What each `make` command really runs

`make` is only a shortcut. The recipes are in [Makefile](../Makefile).

| Command | Tool that runs | What it does | Changes anything? |
|---|---|---|---|
| `make check-api` | `curl` | Calls the cloud API once to prove the URL and token work | No |
| `make init` | Terraform | Downloads the provider plugins | No (local only) |
| `make validate` | Terraform | Checks that the `.tf` files are written correctly | No |
| `make plan` | Terraform | Compares the code, the saved state and the real cloud, and prints the difference | No |
| `make infra` | Terraform | **Applies** the difference: creates VMs, writes `hosts.yml` | **Yes (costs money)** |
| `make destroy` | Terraform | Deletes what Terraform created | **Yes** |
| `make status` | `curl` + `jq` + Terraform output | Lists every VM with its state and IP | No |
| `make ansible-build` | Docker | Builds the Ansible container image | No (local only) |
| `make ping` | Ansible (in Docker) | Can Ansible log in to every VM? | No |
| `make lint-ansible` | ansible-lint (in Docker) | Style and safety check of the Ansible code | No |
| `make check` | Ansible (in Docker) | **Dry run** of `site.yml`: shows what *would* change | No |
| `make config` | Ansible (in Docker) | **Applies** `site.yml`: baseline + k3s on the VMs | **Yes** |
| `make nodes` | Ansible → `kubectl` | Shows the Kubernetes nodes | No |
| `make kubectl ARGS="..."` | Ansible → `kubectl` | Runs any `kubectl` command on the server node | Depends on the command |
| `make deploy` | Ansible → `kubectl apply` | Sends `k8s/` to the server and applies it | **Yes** |
| `make headlamp` | `ssh` | Opens a tunnel so `http://localhost:8080` reaches the UI | No |
| `make headlamp-token` | Ansible → `kubectl` | Prints a login token for the UI | No (creates a short-lived token) |

### Who does what

```
 Terraform  ──▶ talks to the CLOUD API        ──▶ creates / deletes the VMs
            ──▶ writes ansible/inventories/prod/hosts.yml   (the hand-over)
 Ansible    ──▶ talks to the VMs over SSH     ──▶ hardens them, installs k3s, joins nodes
            ──▶ copies k8s/ to the server and runs kubectl there
 Kubernetes ──▶ runs on the VMs               ──▶ runs your apps (Headlamp, anything you add)
```

A good rule: **if it is about the machine existing, it is Terraform. If it is about what is
inside the machine, it is Ansible. If it is about what runs on the cluster, it is Kubernetes
(`k8s/`).**

### How the token reaches Terraform

```
.env  ──(Makefile lines 9-10)──▶  TF_VAR_gcx_api_token  ──▶  var.gcx_api_token
                                                              └─▶ providers.tf:5  "Bearer <token>"
```

- `.env` holds `GCX_API_URL` and `GCX_API_TOKEN`. It is gitignored.
- The Makefile reads it with `sed` and exports `TF_VAR_...` variables. Terraform automatically
  turns any `TF_VAR_name` environment variable into the variable `name`.
- `terraform/envs/prod/providers.tf` puts the token into the `Authorization` header of every API call.

---

## 1. Phase 0: setup before any code runs

| What | How | Why |
|---|---|---|
| API token | Created in the cloud console, saved in `.env` | Terraform needs permission to create things |
| SSH key pair | `ssh-keygen -t ed25519 -f ~/.ssh/homelab` | The private key logs in to VMs, the public key is installed on them |
| Docker | Already on your machine | Ansible runs in a container |
| Terraform | Already installed | Creates the VMs |

Check the API connection (no Terraform, no Ansible involved):
```bash
make check-api        # prints: GCX API /projects: HTTP 200
```
`HTTP 200` means the URL and token work. `401` means a bad token. The recipe is a single
`curl` call at `Makefile:79-82`.

---

## 2. Phase 1: Terraform creates a VM

### The three Terraform files you read first

**`terraform/envs/prod/providers.tf`**: how to reach the cloud.
The cloud used here has no dedicated Terraform provider, so the generic **`restapi`** provider
is used. It turns "create an object" into plain HTTP calls. Line 2 is the API address, lines
4-8 are the headers (the token), line 11 tells it where to find an object's ID in a reply
(`data/slug`, because the API wraps every reply as `{"status":..., "data": {...}}`).

**`terraform/modules/vm/main.tf`**: the request for **one VM**.
A *module* is a reusable block. This one is used for every VM.
- Line 1: `restapi_object "vm"` means "one object managed through the API".
- Line 2: `path = "/virtual-machines"`. On create, Terraform sends `POST /virtual-machines`.
- Lines 4-36: `data = jsonencode({...})` is the JSON body of that request. Each field answers a
  question the API asks: the name, the OS template (`template`), the size (`plan`), the region,
  whether it gets a public IP (`is_public`), which network (`network_plan`, `networks`).
- Line 32: `user_data` is a **cloud-init** script. On first boot the VM runs it and installs
  your public key, so you can log in without a password.
- Lines 38-39: how Terraform finds the VM again later. `read_path = "/virtual-machines/{id}"`
  is called by `make plan` to check the VM still looks right.
- Lines 41-50: how it is **deleted**. This cloud has no `DELETE` for VMs, so deletion is a `POST`
  of a "cancel request". The fields are the ones the API demanded (see the error table).
- Lines 52-57: a `precondition`, a safety check explained in Phase 5.

**`terraform/envs/prod/main.tf`**: which VMs exist and in what order. Phase 5 explains it.

### Commands and what happens

```bash
make plan      # 1. terraform init (once), then: read code + state + cloud, print the difference
make infra     # 2. the same plan, then asks "yes", then performs it
```
When `make infra` runs, for each VM Terraform:
1. Sends `POST /virtual-machines` with the JSON from the module.
2. Reads the ID from the reply (`data/slug`, for example `k3s-01`).
3. Saves it in the **state file**, `terraform/envs/prod/terraform.tfstate` (gitignored).

**Check it worked**
```bash
make status                                   # state of each VM in the cloud
terraform -chdir=terraform/envs/prod state list   # what Terraform thinks it owns
make plan                                     # should say: No changes
```
"No changes" means three things agree: your code, the state file, and the real cloud.

---

## 3. Phase 2: Terraform hands the machines to Ansible

Ansible needs a list of machines. Terraform writes it, so nobody types an IP address by hand.

- **`terraform/envs/prod/inventory.tftpl`** is a template with blanks like `${ansible_user}`.
- **`terraform/envs/prod/main.tf:70-80`**, the `local_file "inventory"` resource, fills the blanks and
  writes the result to `ansible/inventories/prod/hosts.yml`.
- Where does the IP come from? The VM module reads it out of the API reply:
  `terraform/modules/vm/outputs.tf` decodes `api_response` and takes `data.ipaddresses[0].name`.

The generated file looks like this (do not edit it by hand):
```yaml
all:
  vars:
    ansible_user: ubuntu                              # who Ansible logs in as
    common_admin_ssh_public_key: "ssh-ed25519 ..."    # key the baseline installs for devops
    ansible_ssh_private_key_file: /run/keys/homelab   # path INSIDE the container
  children:
    k3s_server: { hosts: { k3s-01: { ansible_host: <ip> } } }
    k3s_agent:  { hosts: { k3s-02: ..., k3s-03: ... } }
```
`k3s_server` and `k3s_agent` are **groups**. Playbooks use them to say "run this on the server
only" or "run this on the agents only".

> **The IP can be empty right after creation.** The VM may not have an address yet when
> Terraform writes the file. Run `make infra` again after the VMs are `Running` and the file is
> refreshed. `make plan` shows `local_file.inventory` changing if the IPs changed.

---

## 4. Phase 3: Ansible in a container

Why a container? Everyone, and later a pipeline, gets the exact same Ansible version.

- **`ansible/Dockerfile`**: starts from a small Python image, installs a pinned `ansible-core` and
  `ansible-lint` (`ansible/requirements.txt`), and the extra modules in `ansible/requirements.yml`.
- **`Makefile:20-24`**, `ANSIBLE_RUN`, is the long `docker run` command every Ansible target reuses:
  - `-v "$(CURDIR):/work"`: the repo appears inside the container at `/work`.
  - `-v "$(SSH_KEY):/run/keys/homelab:ro"`: your private key, **read-only**, never copied into the image.
  - `--rm`: the container is deleted when the command ends. That is why you never see it in `docker ps`.
- **`ansible/ansible.cfg`**: Ansible settings. `StrictHostKeyChecking=accept-new` trusts a host the
  first time and refuses if its key later changes. Host keys are saved in
  `ansible/.ansible/known_hosts`.

```bash
make ansible-build    # docker build: creates the image (once, or when the Dockerfile changes)
make ping             # ansible -i inventories/prod/hosts.yml all -m ping
```
`ping` here is not a network ping. It logs in over SSH, runs a tiny Python check on the VM and
answers `pong`. If it works, Ansible can control the machine.

---

## 5. Phase 4: the `common` role (baseline on every VM)

The entry point is **`ansible/playbooks/site.yml`**. Its first play runs the role `common` on
`hosts: all`. The role's tasks are in `ansible/roles/common/tasks/main.yml`.

```bash
make check     # dry run: "changed=13" means 13 things would change
make config    # the real run
make config    # again: must say changed=0 (idempotent)
```

### The tasks, in order

| Lines | Task | What it does on the VM |
|---|---|---|
| 2-7 | assert | Stops early if the public key variable is empty |
| 9-14 | apt | Installs the packages listed in `roles/common/defaults/main.yml` (`common_packages`) |
| 17-23 | user | Creates the `devops` admin user in the `sudo` group |
| 25-31 | authorized_key | Puts your public key in `devops`'s `~/.ssh/authorized_keys` |
| 33-40 | copy to `/etc/sudoers.d/` | Passwordless sudo, checked with `visudo -cf` before it is saved |
| 45-57 | copy to `/etc/ssh/sshd_config.d/` | SSH hardening: no root, no passwords, 3 attempts |
| 59-61 | `sshd -t` | Tests the SSH config **before** the reload, so a typo cannot lock you out |
| 64-110 | swap tasks | Create a 1 GB swap file, format it, make it permanent, turn it on, set swappiness |
| 115-120 | ufw (ports) | Allow port 22 |
| 122-126 | ufw (networks) | Allow the private subnet, pod network and service network (see Phase 6) |
| 128-136 | ufw (defaults) | Deny incoming, allow outgoing |
| 138-140 | ufw enable | Turn the firewall on **after** the allow rules, so SSH is never cut off |
| 143-155 | copy | Configure the fail2ban SSH jail |
| 157-170 | service | Start and enable fail2ban and chrony |

The **handlers** (`roles/common/handlers/main.yml`) run only when a task says `notify:`. For
example, the SSH config task notifies `Reload sshd`, and the reload happens once at the end, only
if the file really changed.

### Four patterns to learn from this role

1. **Desired state, not commands.** `state: present` means "make sure it exists". It does nothing
   if it already does.
2. **`creates:`** (line 67): a `command` task is skipped if the named file exists. This is how
   one-off commands become idempotent.
3. **`changed_when`** (lines 61, 83, 98, 103): tells Ansible whether a command really changed
   anything, so the recap is honest.
4. **Check-mode tolerance** (`ignore_errors: "{{ ansible_check_mode }}"`): in a dry run, things
   like a new user or a new package do not exist yet, so the next task would fail. These tasks
   are allowed to fail **only** during `--check`. In a real run they are real failures.

Role variables all start with `common_` (`roles/common/defaults/main.yml`). `ansible-lint`
requires it, so two roles can never accidentally share a variable.

---

## 6. Phase 5: three VMs that share one private network

This is the part of the code to read slowly: **`terraform/envs/prod/main.tf`**.

```
module.vm_server ──▶ time_sleep (60s) ──▶ data.restapi_object.server_vm ──▶ module.vm_agent (x2)
   creates k3s-01      let it boot          reads k3s-01's network slug        join that network
                                                                                       │
                                            local_file.inventory  ◀────────────────────┘
```

- **Lines 4-8:** the list of VMs and their role. To add a node, add a line.
- **Lines 10-11:** two filtered copies of the list, `servers` and `agents`.
- **Lines 20-30:** `module "vm_server"` creates the server first. The cloud makes a private
  network for it.
- **Lines 33-36:** `time_sleep` waits 60 seconds. Terraform has no idea when a VM is *ready*, only
  that the API call returned.
- **Lines 38-46:** `data "restapi_object"` is a **read-only lookup**. It asks the API for the
  server by name, which returns the network it is on.
- **Line 50:** `server_network` pulls the network slug out of that reply.
- **Lines 54-66:** `module "vm_agent"` creates the agents and passes `network = local.server_network`.
  Inside the module, `networks = [var.network]` (`terraform/modules/vm/main.tf:25`) puts the VM in
  that network, so the three nodes can talk privately.
- **`require_network = true`** and the `precondition` (module lines 52-57) are a safety net: if the
  network slug is empty, Terraform **refuses to create the agent** instead of silently making a
  separate network. That check fired on the first attempt and saved us.

Terraform works out this order by itself, because each block uses values from the one before.
That is a **dependency graph**, a core Terraform idea.

---

## 7. Phase 6: k3s, the cluster

`ansible/playbooks/site.yml` has four plays, in order:

| Play | Runs on | Role | Result |
|---|---|---|---|
| 1 | `all` | `common` | Baseline everywhere |
| 2 | `k3s_server` | `k3s_server` | Control plane installed |
| 3 | `k3s_agent` | `k3s_agent` | Workers join the cluster |
| 4 | `k3s_server` | (a task) | Waits until all nodes are `Ready` |

### The server: `ansible/roles/k3s_server/tasks/main.yml`
- **Lines 2-8:** downloads the official installer script.
- **Lines 12-23:** runs it. Environment variables steer the installer:
  `INSTALL_K3S_VERSION` pins the version, and `INSTALL_K3S_EXEC` carries the options: the node's
  private address (`--node-ip`), the public address in the certificate (`--tls-san`), a **taint**
  so your apps stay off the small control plane, and `--disable metrics-server` to save RAM.
  `creates:` makes it run once.
- **Lines 25-32:** waits until the node reports `Ready`. `until` + `retries` is Ansible's loop-and-wait.
- **Lines 36-47:** reads the **join token** the server created, and stores it in a variable with
  `set_fact`. `no_log: true` hides the secret from the output.
- **Lines 50-66:** copies the admin kubeconfig to `ansible/.ansible/kubeconfig.yaml` (gitignored,
  it holds admin credentials) and points it at the server's public address.

### The agents: `ansible/roles/k3s_agent/tasks/main.yml`
- **Lines 2-8:** safety check that the server's token is known.
- **Lines 20-30:** runs the same installer, but as an **agent**, with two extra values:
  `K3S_URL` is the **server's private address** on port 6443, and `K3S_TOKEN` is the token read
  from the server. Ansible hands it over with `hostvars[...]`, which lets a task on one host read
  a value created on another host. Nobody copies a secret by hand.

### Shared settings: `ansible/inventories/prod/group_vars/all/vars.yml`
Variables here apply to every host.
- `k3s_version`: the pinned version.
- `common_ufw_allow_from_cidrs`: the firewall rule that lets the nodes talk to each other. It is
  computed from each node's own network facts (`ansible_facts['default_ipv4']`), so no address
  is hard-coded. The pod network (`10.42.0.0/16`) and service network (`10.43.0.0/16`) are
  allowed too, or Kubernetes traffic would be blocked by the VM firewall.

```bash
make config       # runs all four plays
make nodes        # kubectl get nodes -o wide  →  3 nodes, all Ready
make kubectl ARGS="get pods -A -o wide"   # system pods spread over the nodes
```

### Why no Docker?
k3s ships its own container engine, `containerd`. Docker on a 1 GB node would only waste memory.
The `docker` role exists in `ansible/roles/docker/` but is commented out in `site.yml`.

---

## 8. Phase 7: deploying onto the cluster

Kubernetes objects live as YAML files in `k8s/`.

```
k8s/headlamp/helmchart.yaml     a HelmChart object: "install Headlamp, version 0.46.0"
```
k3s has a built-in **Helm controller**. A `HelmChart` object tells it to download and install a
chart, so no Helm program is needed on any machine.

`make deploy` runs **`ansible/playbooks/deploy.yml`**:
1. Creates `/opt/k8s` on the server.
2. Copies the whole `k8s/` folder there.
3. Runs `k3s kubectl apply -R -f /opt/k8s`.

Why through Ansible and not `kubectl` from your laptop? `kubectl` from a laptop needs the
Kubernetes API port (6443) open to the internet. Using SSH, which is already open, avoids that.

**Removing something:** deleting a file from `k8s/` does **not** delete it from the cluster.
`kubectl apply` only adds and changes. Delete the object explicitly
(`make kubectl ARGS="delete namespace <name>"`) and also delete `/opt/k8s/<name>` on the server,
or the next `make deploy` would apply it again.

### Using the UI
```bash
make headlamp-token     # a login token, valid 8 hours
make headlamp           # tunnel; then open http://localhost:8080 and paste the token
```
`make headlamp` is just `ssh -L 8080:127.0.0.1:30080 devops@<worker ip>`: it forwards your local
port 8080 through the encrypted SSH connection to port 30080 on the worker, where Headlamp listens.
**No port is opened to the internet.**

---

## 9. How information moves between the tools

| What | Born where | Path | Used where |
|---|---|---|---|
| API token | `.env` | Makefile → `TF_VAR_...` → provider header | Every API call |
| Public IP | Cloud API reply | `modules/vm/outputs.tf` → `local_file` → `hosts.yml` | `ansible_host` in Ansible |
| Network slug | Cloud API (the server) | `data` lookup → `server_network` → agent module | Agents join the same network |
| Your public key | `~/.ssh/homelab.pub` | `user_data` (first login) and `hosts.yml` → `common` role | Login as `ubuntu`, then `devops` |
| Private IP | The VM's network card | Ansible facts `default_ipv4` | `--node-ip`, `K3S_URL`, firewall rule |
| Join token | The k3s server | `slurp` → `set_fact` → `hostvars` | Agents' `K3S_TOKEN` |
| Kubeconfig | The k3s server | `fetch` → `ansible/.ansible/kubeconfig.yaml` | `kubectl` from a laptop (not used yet) |

---

## 10. Everything that went wrong, and what it taught

| What we saw | Cause | Fix and lesson |
|---|---|---|
| `500` when creating an SSH key | The provider's key endpoint failed for every input | Install the key with cloud-init `user_data` instead. **Lesson: have a second route.** |
| `422` "network_plan field is required" | A required field was missing from the request body | Look the value up with a read-only API call and add it. **Lesson: a rejected request creates nothing, so errors are cheap.** |
| `403` "delete_public_ip field is required" | The delete request lacked a field not in the published docs | Added the field. **Lesson: the saved delete request lives in the state, so a fix only helps *new* resources.** |
| `Resource precondition failed` | The network slug lookup read the wrong level of the reply | Fixed the path (`.data.networks[0]`). **Lesson: the safety check stopped a wrong network from being used.** |
| `Insufficient address capacity` | Two VMs asked for a public IP at the same instant | Created the third one alone. **Lesson: cloud APIs can race. Create things one at a time if they fight over a resource.** |
| `REMOTE HOST IDENTIFICATION HAS CHANGED` | A rebuilt VM got an old IP with a new SSH key | `ssh-keygen -R <ip> -f ansible/.ansible/known_hosts`. **Lesson: this warning protects you, so understand it before clearing it.** |
| Ansible dry run fails on a new user or package | A dry run does not create things, so later tasks cannot find them | `ignore_errors: "{{ ansible_check_mode }}"` on those tasks only. |
| `ansible-lint` `var-naming` | Role variables must start with the role name | Renamed to `common_...`. |
| Shell errors reading `.env` | The token contains a `\|` character | Quote values in `.env`; the Makefile strips the quotes with `sed`. |
| Terraform "unsupported argument" | Invented option names for the `restapi` resource | Read the real schema: `terraform providers schema -json`. **Lesson: check the schema, do not guess.** |

---

## 11. A normal working session

```bash
make status                 # are the VMs up?
make plan                   # does reality match the code?        (expect: No changes)
make check                  # would Ansible change anything?      (expect: changed=0)
make nodes                  # is the cluster healthy?
make deploy                 # apply whatever is in k8s/
```

### Rebuild from nothing (the real test of this project)
```bash
make destroy      # deletes the VMs (read the Caveats below first)
make infra        # creates 3 VMs, writes hosts.yml
make infra        # again, once the VMs are Running: refreshes the IPs
make config       # baseline + k3s on all three
make deploy       # Headlamp
```

### Caveats to remember
- A VM is billed by the hour while it exists. Destroy it when you stop for a while.
- `make destroy` should work for the VMs created with the current code. After a destroy, check the
  cloud console for leftover IPs or networks.
- The state file is local (`terraform/envs/prod/terraform.tfstate`). If you lose it, Terraform forgets
  the VMs. A team would keep it in shared storage.
- Only port 22 is open to the internet. The cluster API (6443) and web ports (80/443) are closed on purpose.
  Open them last, restricted to your own IP, once something is ready to serve.

---

## 12. Read-the-code exercises

Do these in order. Each answer is in the code, not in this document.

1. In `modules/vm/main.tf`, which line decides the VM's size? Change it in `variables.tf` and run
   `make plan`. Does it say *update in place* or *replace*? Why?
2. Follow the public IP: find where it is read from the API reply, where it becomes an output, and
   where it ends up in `hosts.yml`.
3. In `roles/common/tasks/main.yml`, which task makes the second `make config` report `changed=0`
   for swap? (Hint: `creates:` and the `when:` on the last swap task.)
4. In `roles/k3s_agent/tasks/main.yml`, where does `K3S_TOKEN` come from, and on which machine was
   it created?
5. Why is `ufw enable` the **last** firewall task, after the allow rules?
6. Remove `k3s-03` from `locals.vms` in `main.tf` and run `make plan`. What does Terraform want to do?
   (Read it; do not apply it.)
7. Why does `make deploy` go through Ansible instead of running `kubectl` on your laptop?
8. Find every place the word `ignore_errors` appears. What do they all have in common?
