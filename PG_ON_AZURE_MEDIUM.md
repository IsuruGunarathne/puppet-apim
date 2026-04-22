# Deploying the WSO2 API Platform Gateway on Azure

The WSO2 API Platform (APIP) Gateway is a lightweight, Docker Compose–based API gateway that connects to a WSO2 API Manager control plane. Unlike the full APIM stack, the gateway has no UI and no database — it fetches its configuration from the control plane at startup and handles all API traffic. This makes it easy to scale out horizontally or deploy it close to your consumers.

This guide walks you through standing up a gateway VM on Azure that is reachable from the public internet on ports 8080 (HTTP) and 8443 (HTTPS) while keeping its communication with the APIM control plane entirely on a private VNET — the recommended architecture for any production deployment.

```
APIM Control Plane VM ←——— private VNET ———→ APIP Gateway VM ←——— public internet ———→ API consumers
```

---

## Prerequisites

- An Azure subscription with a VNET containing an APIM control plane VM. If you haven't set one up yet, start with [wso2/product-apim](https://github.com/wso2/product-apim) and deploy it on a VM in the same VNET before continuing.
- An SSH key pair on your workstation (`~/.ssh/id_ed25519` or similar).

---

## Step 1 — Provision the Gateway VM

Create the VM in the **same VNET and subnet as your APIM VM**. This is what lets the gateway reach the control plane over a private IP — no public endpoint needed for that traffic.

| Setting | Value |
|---|---|
| OS | Ubuntu Server 22.04 LTS — x64 Gen2 |
| Size | `Standard_B2ms` (2 vCPU, 8 GB RAM) minimum; `Standard_D2s_v5` for production |
| Authentication | SSH public key |
| Virtual network / Subnet | Same VNET and subnet as your APIM VM |
| Public IP | Yes — consumers reach the gateway on this IP |
| OS disk | 30 GB Premium SSD |

Once the VM is created, note its **public IP** from the Overview blade. Add an entry to `/etc/hosts` on your local workstation so you can reference it by hostname:

```
<gateway-public-ip>  apip.wso2.com
```

---

## Step 2 — Configure Inbound NSG Rules

Open the VM's **Networking** blade and edit the auto-created NSG:

| Rule name | Source | Destination port | Protocol | Action |
|---|---|---|---|---|
| `SSH` (edit existing) | Your workstation IP | 22 | TCP | Allow |
| `gateway-http` (add new) | Any | 8080 | TCP | Allow |
| `gateway-https` (add new) | Any | 8443 | TCP | Allow |

Ports 8080 and 8443 are the HTTP and HTTPS ingress listeners on the gateway runtime container. Azure's default outbound rules already allow the gateway VM to reach the control plane on the private VNET, so no outbound changes are needed.

---

## Step 3 — Note the Control Plane's Private IP

From the Azure portal, copy the **private IP** of your APIM VM (e.g. `10.6.0.7`). You'll use it in step 6 to tell the gateway how to resolve `cp.wso2.com` — the hostname the gateway uses internally to reach the control plane.

---

## Step 4 — SSH into the Gateway VM

```bash
ssh azureuser@<gateway-public-ip>
```

---

## Step 5 — Install Docker Engine and the Compose Plugin

```bash
# Refresh packages and install base tools
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg unzip

# Add Docker's official GPG key and repo
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install Docker Engine and Compose plugin
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Add your user to the docker group
sudo usermod -aG docker $USER
```

Run `newgrp docker` to pick up the group in your current session without logging out, then verify:

```bash
docker --version
docker compose version
```

---

## Step 6 — Map the Control Plane Hostname

The gateway resolves the control plane by hostname (`cp.wso2.com`), not by IP. Since the CP is reachable only on the private VNET, add a hosts entry that maps the hostname to its private IP:

```bash
echo "<cp-private-ip>  cp.wso2.com" | sudo tee -a /etc/hosts
```

Confirm the CP is reachable before proceeding:

```bash
curl -vk https://cp.wso2.com:9443/
```

A TLS handshake (even with an error response body) confirms network connectivity is good.

---

## Step 7 — Download the Gateway

```bash
curl -sLO https://github.com/wso2/api-platform/releases/download/gateway/v1.0.0/wso2apip-api-gateway-1.0.0.zip
unzip wso2apip-api-gateway-1.0.0.zip
```

The zip ships a `config-template.toml` but the compose expects `config.toml`. Copy it before starting:

```bash
cp wso2apip-api-gateway-1.0.0/configs/config-template.toml wso2apip-api-gateway-1.0.0/configs/config.toml
```

---

## Step 8 — Configure the Gateway

Generate a registration token from the APIM Admin UI. The token is **single-use** — it is consumed the moment the gateway connects, and generating a new one immediately invalidates any previous token and disconnects the currently registered gateway.

Create `configs/keys.env` with the token and CP address:

```bash
cat > wso2apip-api-gateway-1.0.0/configs/keys.env << 'ENVFILE'
GATEWAY_CONTROLPLANE_HOST=cp.wso2.com:9443
GATEWAY_REGISTRATION_TOKEN=<your-gateway-token>
ENVFILE

chmod 600 wso2apip-api-gateway-1.0.0/configs/keys.env
```

---

## Step 9 — Start the Gateway

```bash
cd wso2apip-api-gateway-1.0.0
docker compose --env-file configs/keys.env up -d
```

Tail the logs to confirm the gateway registers with the CP:

```bash
docker compose logs -f
```

Check that both containers are up:

```bash
docker compose ps
```

---

## Step 10 — Verify Connectivity

From your local workstation:

```bash
curl -vk https://apip.wso2.com:8443/
```

A completed TLS handshake — even with a 404 on the path — confirms the NSG rule is in effect and the gateway is listening. In the APIM control plane UI, the gateway should now appear as connected.

---

## Step 11 — Auto-restart Across Reboots

Docker Engine starts automatically on boot, but Compose stacks don't restart themselves. Wire it up with a systemd unit:

```bash
sudo tee /etc/systemd/system/wso2-gateway.service << 'EOF'
[Unit]
Description=WSO2 API Platform Gateway
Requires=docker.service
After=docker.service network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/home/azureuser/wso2apip-api-gateway-1.0.0
ExecStart=/usr/bin/docker compose --env-file configs/keys.env up -d
ExecStop=/usr/bin/docker compose down
User=azureuser

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now wso2-gateway.service
```

---

## Production Hardening

- Put the gateway behind an Azure Application Gateway or Front Door if you need WAF, TLS termination, or a stable DNS name with a managed certificate.
- Configure Azure Monitor / Log Analytics with the Azure Monitor Agent to ship container logs and VM metrics.
- Enable automatic OS updates (**Settings → Updates → Update management**) and set a maintenance window.
- Take regular snapshots of the OS disk before upgrades.
- Rotate the gateway registration token periodically and store secrets in Azure Key Vault if you script deployments.
- Scope the public NSG rules to known API-consumer IP ranges when possible instead of `Any`.

---

## Troubleshooting

| Symptom | Check |
|---|---|
| `Permission denied` on `docker` commands | Run `newgrp docker` or log out and SSH back in after `usermod -aG docker` |
| `permission denied while trying to connect to the Docker daemon at unix:///var/run/docker.sock` | Same as above — group membership hasn't taken effect yet |
| Gateway logs show TLS/connect errors to `cp.wso2.com:9443` | VNET routing or DNS issue; run `curl -vk https://cp.wso2.com:9443` from the gateway VM |
| Token rejected | Registration tokens are single-use — generate a new one and rewrite `keys.env` |
| Port 8443 unreachable from the internet | Confirm the NSG inbound rule exists and that `docker-compose.yml` maps port 8443 to the host |
| High memory / CPU | Resize the VM to `Standard_D4s_v5` or larger and restart |

---

## Conclusion

At this point you have a WSO2 API Platform Gateway running on Azure, connected to your APIM control plane over a private VNET and exposed to API consumers on ports 8080 and 8443. The gateway pulls its API and policy configuration from the control plane automatically, so any APIs you publish there will be enforced here without further intervention.

From here you can scale horizontally by repeating this guide on additional VMs and registering each with a fresh token, put an Azure Load Balancer in front of them, or enable the observability stack (tracing, metrics, logging) bundled in the zip by starting compose with the relevant profiles.
