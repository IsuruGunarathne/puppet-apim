# Running This Setup on Azure VMs

## 1. Decide Your Deployment Pattern

For a simple distributed setup you'll need these VMs:

| VM | Role | Puppet Profile |
|---|---|---|
| `puppet-master` | Puppet Master | (not an agent) |
| `apim-cp` | Control Plane | `apim_control_plane` |
| `apim-gw` | Gateway | `apim_gateway` |
| `apim-tm` | Traffic Manager | `apim_tm` |
| `apim-km` | Key Manager | `apim_km` |
| `db-server` | MySQL (external DB) | (not an agent) |

For a simple all-in-one test, you only need `puppet-master` + one `apim` VM.

---

## 2. Create the Azure VMs

Create all VMs in the **same VNet and subnet** so they can talk to each other by private IP.

Recommended specs per VM:
- **Puppet Master**: Standard_B2s (2 vCPU, 4GB RAM), Ubuntu 22.04
- **APIM nodes**: Standard_D4s_v3 (4 vCPU, 16GB RAM), Ubuntu 22.04
- **DB server**: Standard_D2s_v3, Ubuntu 22.04

```bash
az group create --name apim-rg --location eastus

az network vnet create \
  --resource-group apim-rg \
  --name apim-vnet \
  --address-prefix 10.0.0.0/16 \
  --subnet-name apim-subnet \
  --subnet-prefix 10.0.1.0/24

az vm create \
  --resource-group apim-rg \
  --name puppet-master \
  --image Ubuntu2204 \
  --vnet-name apim-vnet \
  --subnet apim-subnet \
  --admin-username azureuser \
  --generate-ssh-keys \
  --size Standard_B2s
```

Repeat `az vm create` for each node (`apim-cp`, `apim-gw`, `apim-tm`, `apim-km`, `db-server`).

---

## 3. Configure DNS / Hostnames

Edit `/etc/hosts` on **every VM** with each node's private IP:

```
10.0.1.10  puppet puppet-master.apim.local
10.0.1.11  apim-cp cp.wso2.com
10.0.1.12  apim-gw gw.wso2.com
10.0.1.13  apim-tm tm.wso2.com
10.0.1.14  apim-km km.wso2.com
10.0.1.20  db-server db.wso2.com
```

---

## 4. Open Required Ports (Network Security Group)

Allow all traffic within the VNet, then add specific inbound rules for external access:

| Port | Protocol | Purpose |
|---|---|---|
| 8243 | HTTPS | Gateway (API traffic) |
| 9443 | HTTPS | Control Plane management UI |
| 8140 | TCP | Puppet Master ← Agents (internal only) |
| 5672 | TCP | JMS (TM ↔ Gateway) — internal only |
| 9611/9711 | TCP | Thrift (TM stats) — internal only |
| 3306 | TCP | MySQL — internal only |

```bash
az network nsg rule create \
  --resource-group apim-rg \
  --nsg-name puppet-master-nsg \
  --name allow-puppet \
  --priority 100 \
  --source-address-prefixes 10.0.1.0/24 \
  --destination-port-ranges 8140 \
  --protocol Tcp
```

---

## 5. Install Puppet Server on the Master

SSH into `puppet-master`:

```bash
wget https://apt.puppet.com/puppet8-release-jammy.deb
sudo dpkg -i puppet8-release-jammy.deb
sudo apt update
sudo apt install puppetserver -y

sudo bash -c 'cat >> /etc/puppetlabs/puppet/puppet.conf << EOF
[master]
dns_alt_names = puppet,puppet-master.apim.local
EOF'

sudo systemctl enable puppetserver
sudo systemctl start puppetserver
```

---

## 6. Clone This Repo onto the Puppet Master

```bash
cd /etc/puppetlabs/code/environments/
sudo git clone --single-branch --branch 4.6.x https://github.com/wso2/puppet-apim.git production
```

Place the product packs:

```bash
sudo cp wso2am-4.6.0.zip \
  /etc/puppetlabs/code/environments/production/modules/apim_common/files/packs/

sudo cp amazon-corretto-17.0.6.10.1-linux-x64.tar.gz \
  /etc/puppetlabs/code/environments/production/modules/apim_common/files/jdk/
```

---

## 7. Configure params.pp for Each Profile

Edit each module's `params.pp` to point to your actual Azure VM hostnames. For example, `modules/apim_control_plane/manifests/params.pp`:

```puppet
$hostname = 'cp.wso2.com'

$wso2am_db_url      = 'jdbc:mysql://db.wso2.com:3306/apimgt'
$wso2am_db_username = 'apimuser'
$wso2am_db_password = 'yourpassword'
$wso2am_db_type     = 'mysql'

$wso2shared_db_url  = 'jdbc:mysql://db.wso2.com:3306/shareddb'

$throttle_decision_endpoints = '"tcp://tm.wso2.com:5672"'
```

Use `docs/samples/distributed_km_seperated/` as a reference for all profiles.

---

## 8. Install Puppet Agent on Each Node

SSH into each APIM VM and run:

```bash
wget https://apt.puppet.com/puppet8-release-jammy.deb
sudo dpkg -i puppet8-release-jammy.deb
sudo apt update
sudo apt install puppet-agent -y

sudo bash -c 'cat >> /etc/puppetlabs/puppet/puppet.conf << EOF
[main]
certname = apim-cp.apim.local
server = puppet-master.apim.local
[agent]
environment = production
EOF'
```

---

## 9. Sign Certificates and Apply

On each agent, request a cert:

```bash
sudo /opt/puppetlabs/bin/puppet agent --test --waitforcert 60
```

On the Puppet Master, sign them all:

```bash
sudo /opt/puppetlabs/bin/puppetserver ca sign --all
```

Back on each agent, set the profile fact and apply:

```bash
# Control Plane VM:
echo "profile=apim_control_plane" | sudo tee /etc/puppetlabs/facter/facts.d/profile.txt
sudo /opt/puppetlabs/bin/puppet agent -vt

# Gateway VM:
echo "profile=apim_gateway" | sudo tee /etc/puppetlabs/facter/facts.d/profile.txt
sudo /opt/puppetlabs/bin/puppet agent -vt

# Traffic Manager VM:
echo "profile=apim_tm" | sudo tee /etc/puppetlabs/facter/facts.d/profile.txt
sudo /opt/puppetlabs/bin/puppet agent -vt

# Key Manager VM:
echo "profile=apim_km" | sudo tee /etc/puppetlabs/facter/facts.d/profile.txt
sudo /opt/puppetlabs/bin/puppet agent -vt
```

---

## 10. Verify

```bash
# Check service status on any agent
sudo systemctl status wso2apim_control_plane

# Check logs
tail -f /mnt/apim_control_plane/wso2am-acp-4.6.0/repository/logs/wso2carbon.log
```

Access the Control Plane UI at `https://<apim-cp-public-ip>:9443/publisher`.

---

## Key Things to Get Right

- **All VMs must resolve each other's hostnames** — get `/etc/hosts` right before running Puppet.
- **The Puppet Master hostname must match** what agents have in `puppet.conf server =`.
- **DB must be provisioned first** — create the `apimgt` and `shareddb` MySQL databases and grant the user permissions before running the APIM agents.
- **Start order matters**: bring up TM → CP → Gateway → KM.
