ENV    ?= prod
TF_DIR := terraform/envs/$(ENV)

# GCX_API_URL and GCX_API_TOKEN come from .env (gitignored, see .env.example).
# They are handed to Terraform as TF_VAR_* environment variables.
ifneq ($(wildcard .env),)
# Read the values with sed (not `include`) so quotes are stripped and
# characters like | in the token are kept as-is.
export TF_VAR_gcx_api_url   := $(shell sed -n "s/^GCX_API_URL='\(.*\)'$$/\1/p" .env)
export TF_VAR_gcx_api_token := $(shell sed -n "s/^GCX_API_TOKEN='\(.*\)'$$/\1/p" .env)
else
$(warning .env not found: copy .env.example to .env and fill in your token)
endif

# Ansible runs inside a container (ansible/Dockerfile). The repo is mounted at
# /work and the lab private key is mounted read-only, never copied into the image.
ANSIBLE_IMAGE := homelab-ansible
SSH_KEY       ?= $(HOME)/.ssh/homelab
INVENTORY     := inventories/$(ENV)/hosts.yml
ANSIBLE_RUN   := docker run --rm -t \
	-v "$(CURDIR):/work" \
	-v "$(SSH_KEY):/run/keys/homelab:ro" \
	-e ANSIBLE_CONFIG=/work/ansible/ansible.cfg \
	$(ANSIBLE_IMAGE)

.PHONY: status nodes deploy kubectl headlamp headlamp-token check-api ansible-build ping lint-ansible check config init validate plan infra destroy fmt

ansible-build:
	docker build -t $(ANSIBLE_IMAGE) ansible

# Can Ansible reach every host in the inventory?
ping:
	@mkdir -p ansible/.ansible
	$(ANSIBLE_RUN) ansible -i $(INVENTORY) all -m ping

lint-ansible:
	$(ANSIBLE_RUN) ansible-lint

# Apply everything in k8s/ to the cluster.
deploy:
	@mkdir -p ansible/.ansible
	$(ANSIBLE_RUN) ansible-playbook -i $(INVENTORY) playbooks/deploy.yml

# Run any kubectl command on the server node, e.g.:  make kubectl ARGS="get pods -A -o wide"
kubectl:
	@mkdir -p ansible/.ansible
	@$(ANSIBLE_RUN) ansible -i $(INVENTORY) k3s_server -b -m command -a "/usr/local/bin/k3s kubectl $(ARGS)" | sed 1d

# Open Headlamp on your own machine: an SSH tunnel to a worker node, no public port needed.
# Then browse to http://localhost:8080 (the tunnel is encrypted). Ctrl+C stops it.
headlamp:
	@ip=$$(terraform -chdir=$(TF_DIR) output -json public_ips | jq -r '."k3s-02"'); \
	echo "Headlamp: http://localhost:8080   (Ctrl+C to close the tunnel)"; \
	ssh -i $(SSH_KEY) -N -L 8080:127.0.0.1:30080 \
	  -o UserKnownHostsFile=$(CURDIR)/ansible/.ansible/known_hosts -o StrictHostKeyChecking=accept-new \
	  devops@$$ip

# Print a login token for Headlamp (valid for 8 hours). Treat it like a password.
headlamp-token:
	@$(ANSIBLE_RUN) ansible -i $(INVENTORY) k3s_server -b -m command \
	  -a "/usr/local/bin/k3s kubectl create token headlamp -n headlamp --duration=8h" | sed 1d

# Show the Kubernetes nodes (runs kubectl on the server node).
nodes:
	@mkdir -p ansible/.ansible
	@$(ANSIBLE_RUN) ansible -i $(INVENTORY) k3s_server -b -m command -a "/usr/local/bin/k3s kubectl get nodes -o wide" | sed 1d

# Dry run: show what WOULD change on the hosts, change nothing.
check:
	@mkdir -p ansible/.ansible
	$(ANSIBLE_RUN) ansible-playbook -i $(INVENTORY) playbooks/site.yml --check --diff

# Apply the full configuration to all hosts.
config:
	@mkdir -p ansible/.ansible
	$(ANSIBLE_RUN) ansible-playbook -i $(INVENTORY) playbooks/site.yml

# Read-only call to confirm the URL and token in .env work.
check-api:
	@curl -s -m 30 -o /dev/null -w "GCX API /projects: HTTP %{http_code}\n" \
	  -H "Authorization: Bearer $$TF_VAR_gcx_api_token" -H "Accept: application/json" \
	  "$$TF_VAR_gcx_api_url/projects"

# Status of every VM in the account: name, state (Running/Starting/Error) and public IP.
# The state comes from the cloud API; the IPs come from Terraform's outputs.
status:
	@ips=$$(terraform -chdir=$(TF_DIR) output -json public_ips 2>/dev/null || echo '{}'); \
	curl -s -m 30 -H "Authorization: Bearer $$TF_VAR_gcx_api_token" -H "Accept: application/json" \
	  "$$TF_VAR_gcx_api_url/virtual-machines" \
	| jq -r --argjson ips "$$ips" \
	  '(["NAME","STATE","PUBLIC_IP"] | @tsv), (.data[]? | [.name, .state, ($$ips[.name] // "-")] | @tsv)' \
	| column -t -s "$$(printf '\t')"

init:
	terraform -chdir=$(TF_DIR) init

validate: init
	terraform -chdir=$(TF_DIR) validate

plan: init
	terraform -chdir=$(TF_DIR) plan

infra: init
	terraform -chdir=$(TF_DIR) apply

destroy:
	terraform -chdir=$(TF_DIR) destroy

fmt:
	terraform fmt -recursive terraform
