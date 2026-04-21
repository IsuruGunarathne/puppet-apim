# Deploying the WSO2 API Platform Gateway on an Azure VM

This guide walks you through provisioning an Azure VM via the Azure Portal, hardening its network rules, installing the prerequisites, and running the WSO2 API Platform Gateway so that it is reachable from the public internet while keeping SSH access restricted to you.

---

## 1. Provision the Azure VM (Portal)

Sign in to the [Azure Portal](https://portal.azure.com) and click **Create a resource** → **Virtual machine**.

**Basics tab:**

- **Subscription / Resource group:** pick an existing resource group or click *Create new* (e.g., `rg-wso2-gateway`).
- **Virtual machine name:** `wso2-apip-gw-01` (or similar).
- **Region:** choose the region closest to your API consumers.
- **Availability options:** *No infrastructure redundancy required* is fine for a single-node gateway; use an availability set or zones if you plan to run multiple.
- **Security type:** *Standard* (or Trusted launch if you prefer).
- **Image:** `Ubuntu Server 22.04 LTS - x64 Gen2`.
- **Size:** at minimum `Standard_B2ms` (2 vCPU, 8 GB RAM). For production traffic, prefer `Standard_D2s_v5` or larger. The gateway plus Docker typically needs at least 4 GB RAM; 8 GB gives headroom.
- **Authentication type:** *SSH public key*. Paste the public key from your workstation (`~/.ssh/id_ed25519.pub` or `~/.ssh/id_rsa.pub`). If you don't have one, run `ssh-keygen -t ed25519` on your workstation first.
- **Username:** `azureuser` (or your choice).
- **Public inbound ports:** select *Allow selected ports* → **SSH (22)**. You'll add the gateway ports in step 2.

**Disks tab:** Premium SSD, 30 GB OS disk is sufficient to start. Increase if you expect heavy logging.

**Networking tab:**

- Let Azure create a new **Virtual network**, **Subnet**, and **Public IP**.
- **NIC network security group:** *Basic* is fine for now — we'll customize it in step 2.
- Leave *Accelerated networking* enabled (it's on by default for supported sizes).

Click **Review + create**, then **Create**. Wait for deployment to finish and note the **Public IP address** from the VM's Overview blade.

> **Local workstation hosts entry:** Once you have the public IP, add the following line to `/etc/hosts` on your local machine so that `apip.wso2.com` resolves to the VM:
> ```
> <public-ip>  apip.wso2.com
> ```
> On macOS/Linux this is `/etc/hosts` (requires `sudo`). On Windows it is `C:\Windows\System32\drivers\etc\hosts`.

---

## 2. Configure the Network Security Group (NSG)

From the VM's page, open **Networking** → **Network settings**. You'll see the NSG attached to the NIC. Add the inbound rules below.

**Restrict SSH to your own IP** (edit the existing `SSH` rule):

- Source: *IP Addresses*
- Source IP: your workstation's public IP (find it at [ifconfig.me](https://ifconfig.me))
- Destination port: `22`
- Protocol: TCP, Action: Allow, Priority: 300

**Add gateway data-plane rules** (click *Add inbound port rule* for each):

| Name | Source | Source port | Destination port | Protocol | Priority |
|---|---|---|---|---|---|
| `gateway-https` | Any | * | `8443` | TCP | 320 |

> The ports above are the standard WSO2 gateway listen ports. After you unzip the gateway in step 5, check `wso2apip-api-gateway-1.0.0/docker-compose.yml` for the `ports:` section and adjust your NSG rules if the actual mapped host ports differ.

**Outbound:** the default Azure outbound rules already allow the gateway to reach `cp.wso2.com:9443`, so no changes are needed there.

---

## 3. Connect to the VM

From your workstation:

```bash
ssh azureuser@<public-ip>
```

If the connection fails, double-check the NSG SSH rule source IP and that your key was uploaded correctly.

---

## 4. Install the prerequisites

Run the following on the VM to install cURL, unzip, Docker Engine, and the Docker Compose plugin (official Docker repo, Ubuntu 22.04):

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

# Let your user run docker without sudo (log out and back in afterwards)
sudo usermod -aG docker $USER
```

Log out and SSH back in so the `docker` group membership takes effect, then verify:

> **If you need the group to take effect immediately without logging out**, run `newgrp docker` in your current session. This opens a new shell with the `docker` group active. Alternatively, prefix docker commands with `sudo` as a one-off.

```bash
docker --version
docker compose version
```

---

## 4.5. Add the control-plane host entry on the VM

The gateway container resolves `cp.wso2.com` at runtime. If the control plane is on-prem (not publicly resolvable as `cp.wso2.com`), add a hosts entry on the VM so that name points to the correct IP:

```bash
echo "<cp-private-ip>  cp.wso2.com" | sudo tee -a /etc/hosts
```

Replace `<cp-private-ip>` with the private (LAN) IP of your control-plane host — no public IP needed since the gateway contacts it over the internal network. Confirm resolution before proceeding:

```bash
curl -vk https://cp.wso2.com:9443/
```

---

## 5. Download the gateway

Still on the VM:

```bash
curl -sLO https://github.com/wso2/api-platform/releases/download/gateway/v1.0.0/wso2apip-api-gateway-1.0.0.zip && \
unzip wso2apip-api-gateway-1.0.0.zip
```

---

## 6. Configure the gateway

Generate a fresh registration token in the WSO2 control plane (the token is single-use — a new one revokes any previous token and disconnects the current gateway). Then create `configs/keys.env`:

```bash
cat > wso2apip-api-gateway-1.0.0/configs/keys.env << 'ENVFILE'
GATEWAY_CONTROLPLANE_HOST=cp.wso2.com:9443
GATEWAY_REGISTRATION_TOKEN=<your-gateway-token>
GATEWAY_CONTROLPLANE_ON_PREM=true
ENVFILE
```

Replace `<your-gateway-token>` with the token you just generated. If you want Moesif analytics, append `MOESIF_KEY=<your-moesif-key>` on a new line inside the file.

Secure the file since it contains a secret:

```bash
chmod 600 wso2apip-api-gateway-1.0.0/configs/keys.env
```

---

## 7. Start the gateway

```bash
cd wso2apip-api-gateway-1.0.0
docker compose --env-file configs/keys.env up -d
```

The `-d` flag runs the containers in the background so you can close your SSH session without stopping the gateway. Tail logs with:

```bash
docker compose logs -f
```

Check running containers:

```bash
docker compose ps
```

---

## 8. Verify connectivity

From your workstation (or any external host):

```bash
curl -vk https://<public-ip>:8243/
```

A TLS handshake that completes (even with a 404 on the path) confirms that the NSG is open and the gateway is listening. In the WSO2 control plane UI, the gateway should now show as connected.

---

## 9. Keep the gateway running across reboots

Docker Engine starts automatically at boot on Ubuntu, but you should also make sure the containers restart. Either:

- Add `restart: unless-stopped` to each service in `docker-compose.yml`, or
- Create a small systemd unit that runs `docker compose up -d` in the gateway directory at boot.

Example systemd unit at `/etc/systemd/system/wso2-gateway.service`:

```ini
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
```

Then enable it:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now wso2-gateway.service
```

---

## 10. Production hardening checklist

- Put the gateway behind an Azure Application Gateway or Front Door if you need WAF, TLS termination, or a stable DNS name with a managed certificate.
- Configure Azure Monitor / Log Analytics with the Azure Monitor Agent to ship container logs and VM metrics.
- Enable automatic OS updates (**Settings → Updates → Update management**) and set a maintenance window.
- Take regular snapshots of the OS disk before upgrades.
- Rotate the gateway registration token periodically and store secrets in Azure Key Vault if you script deployments.
- Scope the public NSG rules to known API-consumer IP ranges when possible instead of `Any`.

---

## Troubleshooting quick reference

| Symptom | Check |
|---|---|
| `Permission denied` on `docker` commands | You haven't logged out/in after `usermod -aG docker` |
| `permission denied while trying to connect to the Docker daemon at unix:///var/run/docker.sock` | Run `newgrp docker` to pick up the group in the current session without logging out, or log out and SSH back in |
| Gateway logs show TLS/connect errors to `cp.wso2.com:9443` | VM outbound NSG/route or DNS issue; run `curl -vk https://cp.wso2.com:9443` from the VM |
| Token rejected | Registration tokens are single-use — generate a new one and rewrite `keys.env` |
| Port unreachable from the internet | Confirm the NSG inbound rule exists and that the port in `docker-compose.yml` matches |
| High memory/CPU | Resize the VM to `Standard_D4s_v5` or larger and restart |
