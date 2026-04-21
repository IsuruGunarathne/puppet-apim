# Azure Guide: Distributed WSO2 API Manager with PostgreSQL

This guide sets up a distributed deployment on Azure. The puppet-master and db VMs from the all-in-one setup are reused.

| VM | Role | Puppet Profile | Private IP |
|---|---|---|---|
| `puppet-master` | Puppet Master | (not an agent) | 10.6.0.4 |
| `db` | PostgreSQL database | (not an agent) | 10.6.0.6 |
| `apim-cp` | Control Plane | `apim_control_plane` | 10.6.0.7 |
| `apim-gw` | Gateway | `apim_gateway` | 10.6.0.8 |
| `apim-tm` | Traffic Manager | `apim_tm` | 10.6.0.9 |
| `apim-km` | Key Manager | `apim_km` | 10.6.0.10 |

---

## 1. Create the Azure VMs

Add the new APIM nodes to the existing resource group and VNet:

```bash
for NAME in apim-cp apim-gw apim-tm apim-km; do
  az vm create \
    --resource-group apim-rg \
    --name $NAME \
    --image Ubuntu2204 \
    --vnet-name apim-vnet \
    --subnet apim-subnet \
    --admin-username azureuser \
    --generate-ssh-keys \
    --size Standard_D4s_v3
done
```

Get the private IPs:
```bash
az vm list-ip-addresses --resource-group apim-rg --output table
```

---

## 2. Open Required Ports (NSG)

| Port | VM | Purpose |
|---|---|---|
| 9443 | apim-cp | Control Plane UI (Publisher, DevPortal, Admin) — public |
| 8243 | apim-gw | HTTPS API traffic — public |
| 8280 | apim-gw | HTTP API traffic — public |
| 8140 | puppet-master | Puppet agent communication — internal only |
| 5432 | db | PostgreSQL — internal only |
| 5672 | apim-tm | JMS (TM ↔ Gateway) — internal only |
| 9611/9711 | apim-tm | Thrift (stats publishing) — internal only |

```bash
az vm open-ports --resource-group apim-rg --name apim-cp --ports 9443
az vm open-ports --resource-group apim-rg --name apim-gw --ports 8243,8280
```

---

## 3. Configure /etc/hosts on All VMs

SSH into **every VM** (including puppet-master and db) and add all node entries. Replace IPs with your actual private IPs:

```bash
sudo tee -a /etc/hosts << 'EOF'
10.6.0.4   puppet puppet-master.apim.local
10.6.0.6   db db.wso2.com
10.6.0.7   apim-cp cp.wso2.com
10.6.0.8   apim-gw gw.wso2.com
10.6.0.9   apim-tm tm.wso2.com
10.6.0.10  apim-km km.wso2.com
EOF
```

---

## 4. Initialize Databases on the DB VM

Safe to re-run — drops and recreates the databases from scratch each time.

> **Before re-running on an existing setup**: stop all APIM services first so no active connections block the drop:
> ```bash
> # On apim-cp, apim-gw, apim-tm, apim-km:
> sudo systemctl stop wso2apim_control_plane wso2apim_gateway wso2apim_tm wso2apim_km 2>/dev/null; true
> ```

```bash
sudo apt update
sudo apt install postgresql postgresql-contrib unzip -y

# Allow remote connections (idempotent — sed only changes the line if still commented out)
sudo sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/" \
  /etc/postgresql/*/main/postgresql.conf

# Increase max_connections — 4 WSO2 services each open multiple pools; default 100 is not enough
sudo sed -i "s/^max_connections = .*/max_connections = 400/" \
  /etc/postgresql/*/main/postgresql.conf

# Add subnet access rule only if not already present
grep -qF "10.6.0.0/24" /etc/postgresql/*/main/pg_hba.conf || \
  echo "host all all 10.6.0.0/24 md5" | sudo tee -a /etc/postgresql/*/main/pg_hba.conf

sudo systemctl restart postgresql

# Drop and recreate databases (safe to re-run)
sudo -u postgres psql << 'EOF'
SELECT pg_terminate_backend(pid) FROM pg_stat_activity
  WHERE datname IN ('apimgt','shareddb') AND pid <> pg_backend_pid();
DROP DATABASE IF EXISTS apimgt;
DROP DATABASE IF EXISTS shareddb;
DROP USER IF EXISTS apimuser;
CREATE USER apimuser WITH PASSWORD 'apimpassword';
CREATE DATABASE apimgt;
CREATE DATABASE shareddb;
GRANT ALL PRIVILEGES ON DATABASE apimgt TO apimuser;
GRANT ALL PRIVILEGES ON DATABASE shareddb TO apimuser;
\c apimgt
GRANT ALL ON SCHEMA public TO apimuser;
\c shareddb
GRANT ALL ON SCHEMA public TO apimuser;
EOF

# Initialize schemas
cd ~
wget -O wso2am-4.7.0.zip https://github.com/wso2/product-apim/releases/download/v4.7.0-rc/wso2am-4.7.0-rc.zip
unzip wso2am-4.7.0.zip
PGPASSWORD=apimpassword psql -h localhost -U apimuser -d apimgt -f wso2am-4.7.0/dbscripts/apimgt/postgresql.sql
PGPASSWORD=apimpassword psql -h localhost -U apimuser -d shareddb -f wso2am-4.7.0/dbscripts/postgresql.sql
rm -rf wso2am-4.7.0 wso2am-4.7.0.zip
```

---

## 5. Set Up Puppet Master

If reusing the puppet-master from the all-in-one setup, skip the install and go straight to cloning the repo.

**Install Puppet Server (skip if already done):**

```bash
wget -O puppet8.deb https://apt.puppet.com/puppet8-release-jammy.deb
sudo dpkg -i puppet8.deb
sudo apt update
sudo apt install puppetserver -y

sudo bash -c 'cat >> /etc/puppetlabs/puppet/puppet.conf << EOF
[master]
dns_alt_names = puppet,puppet-master.apim.local
EOF'

sudo systemctl enable puppetserver
sudo systemctl start puppetserver
```

**Clone the repo:**

```bash
cd /etc/puppetlabs/code/environments/
sudo rm -rf production
sudo git clone --single-branch --branch 4.7.test https://github.com/IsuruGunarathne/puppet-apim.git production
```

**Download product pack, JDK, and JDBC driver:**

```bash
# WSO2 packs (each profile needs its own pack; KM reuses the ACP pack)
sudo wget -O /etc/puppetlabs/code/environments/production/modules/apim_common/files/packs/wso2am-acp-4.7.0.zip \
  https://github.com/wso2/product-apim/releases/download/v4.7.0-rc/wso2am-acp-4.7.0-rc.zip

sudo wget -O /etc/puppetlabs/code/environments/production/modules/apim_common/files/packs/wso2am-universal-gw-4.7.0.zip \
  https://github.com/wso2/product-apim/releases/download/v4.7.0-rc/wso2am-universal-gw-4.7.0-rc.zip

sudo wget -O /etc/puppetlabs/code/environments/production/modules/apim_common/files/packs/wso2am-tm-4.7.0.zip \
  https://github.com/wso2/product-apim/releases/download/v4.7.0-rc/wso2am-tm-4.7.0-rc.zip

# Amazon Corretto 21 (JDK)
sudo wget -O /etc/puppetlabs/code/environments/production/modules/apim_common/files/jdk/amazon-corretto-21.0.5.11.1-linux-x64.tar.gz \
  https://corretto.aws/downloads/resources/21.0.5.11.1/amazon-corretto-21.0.5.11.1-linux-x64.tar.gz

# PostgreSQL JDBC driver (add to each profile module that connects to the DB)
for MODULE in apim_control_plane apim_gateway apim_tm apim_km; do
  sudo mkdir -p /etc/puppetlabs/code/environments/production/modules/$MODULE/files/repository/components/lib/
  sudo wget -O /etc/puppetlabs/code/environments/production/modules/$MODULE/files/repository/components/lib/postgresql-42.7.3.jar \
    https://jdbc.postgresql.org/download/postgresql-42.7.3.jar
done
```

---

## 6. Configure params.pp for Each Profile

Edit each module's `params.pp` under `/etc/puppetlabs/code/environments/production/modules/`. Use `docs/samples/distributed_km_seperated/` as a reference.

Common settings to update in every profile:

```puppet
$jvmxms = '256m'
$jvmxmx = '2048m'

$file_list = [
  'repository/components/lib/postgresql-42.7.3.jar'
]

$wso2am_db_url              = 'jdbc:postgresql://db.wso2.com:5432/apimgt'
$wso2am_db_username         = 'apimuser'
$wso2am_db_password         = 'apimpassword'
$wso2am_db_type             = 'postgre'
$wso2am_db_validation_query = 'SELECT 1'

$wso2shared_db_url              = 'jdbc:postgresql://db.wso2.com:5432/shareddb'
$wso2shared_db_username         = 'apimuser'
$wso2shared_db_password         = 'apimpassword'
$wso2shared_db_type             = 'postgre'
$wso2shared_db_validation_query = 'SELECT 1'
```

Profile-specific hostname settings:

| Profile | `$hostname` |
|---|---|
| `apim_control_plane` | `cp.wso2.com` |
| `apim_gateway` | `gw.wso2.com` |
| `apim_tm` | `tm.wso2.com` |
| `apim_km` | `km.wso2.com` |

In `apim_control_plane/manifests/params.pp`, also update:
```puppet
$throttle_decision_endpoints = '"tcp://tm.wso2.com:5672"'
$throttling_url_group = [
  {
    traffic_manager_urls      => '"tcp://tm.wso2.com:9611"',
    traffic_manager_auth_urls => '"ssl://tm.wso2.com:9711"'
  }
]
```

In `apim_gateway/manifests/params.pp`, also update:
```puppet
$key_manager_server_url = 'https://km.wso2.com:${mgt.transport.https.port}${carbon.context}services/'
```

---

## 7. Install Puppet Agent on Each Node

SSH into each APIM VM and run (replacing `<certname>` with the node-specific value from the table below):

```bash
wget -O puppet8.deb https://apt.puppet.com/puppet8-release-jammy.deb
sudo dpkg -i puppet8.deb
sudo apt update
sudo apt install puppet-agent -y

sudo bash -c "cat >> /etc/puppetlabs/puppet/puppet.conf << EOF
[main]
certname = <certname>
server = puppet-master.apim.local
[agent]
environment = production
EOF"
```

| VM | `certname` |
|---|---|
| `apim-cp` | `apim-cp.apim.local` |
| `apim-gw` | `apim-gw.apim.local` |
| `apim-tm` | `apim-tm.apim.local` |
| `apim-km` | `apim-km.apim.local` |

---

## 8. Sign Certificates and Apply

On each agent VM, set the profile fact first, then request a cert:

```bash
# On apim-cp:
sudo mkdir -p /etc/puppetlabs/facter/facts.d
echo "profile=apim_control_plane" | sudo tee /etc/puppetlabs/facter/facts.d/profile.txt
sudo /opt/puppetlabs/bin/puppet agent --test --waitforcert 300

# On apim-gw:
sudo mkdir -p /etc/puppetlabs/facter/facts.d
echo "profile=apim_gateway" | sudo tee /etc/puppetlabs/facter/facts.d/profile.txt
sudo /opt/puppetlabs/bin/puppet agent --test --waitforcert 300

# On apim-tm:
sudo mkdir -p /etc/puppetlabs/facter/facts.d
echo "profile=apim_tm" | sudo tee /etc/puppetlabs/facter/facts.d/profile.txt
sudo /opt/puppetlabs/bin/puppet agent --test --waitforcert 300

# On apim-km:
sudo mkdir -p /etc/puppetlabs/facter/facts.d
echo "profile=apim_km" | sudo tee /etc/puppetlabs/facter/facts.d/profile.txt
sudo /opt/puppetlabs/bin/puppet agent --test --waitforcert 300
```

On the `puppet-master`, sign all certs (within 5 minutes):

```bash
sudo /opt/puppetlabs/bin/puppetserver ca sign --all
```

Once signed, the agents will apply the catalog automatically. If the `--waitforcert` window expired before signing, re-run manually on each agent:

```bash
sudo /opt/puppetlabs/bin/puppet agent -vt
```

**Start order matters**: TM → CP → Gateway → KM.

---

## 9. Verify

```bash
# Control Plane
sudo systemctl status wso2apim_control_plane
tail -f /mnt/apim_control_plane/wso2am-acp-4.7.0/repository/logs/wso2carbon.log

# Gateway
sudo systemctl status wso2apim_gateway
tail -f /mnt/apim_gateway/wso2am-universal-gw-4.7.0/repository/logs/wso2carbon.log

# Traffic Manager
sudo systemctl status wso2apim_tm
tail -f /mnt/apim_tm/wso2am-tm-4.7.0/repository/logs/wso2carbon.log

# Key Manager
sudo systemctl status wso2apim_km
tail -f /mnt/apim_km/wso2am-km-4.7.0/repository/logs/wso2carbon.log
```

**Verify the Gateway's event hub connection** (on `apim-gw` after all services are up):

```bash
grep -i "keyManager\|5672" /mnt/apim_gateway/wso2am-universal-gw-4.7.0/repository/logs/wso2carbon.log | tail -5
```

You should see `Connection successfully created … Host: cp.wso2.com | Port: 5672` and `Started to listen on destination : keyManager`. If you see timeout errors instead, check that port 5672 is reachable from the Gateway:

```bash
nc -zv cp.wso2.com 5672
```

On **your local machine**, add the public IPs to `/etc/hosts`:

```
<apim-cp-public-ip>   cp.wso2.com
<apim-gw-public-ip>   gw.wso2.com
<apim-km-public-ip>   km.wso2.com
```

> **Note:** Make sure each hostname appears only once. Duplicate entries cause macOS/Linux to use the first match, which can send traffic to the wrong IP.

Then access:
- **Publisher**: `https://cp.wso2.com:9443/publisher`
- **Developer Portal**: `https://cp.wso2.com:9443/devportal`
- **Admin**: `https://cp.wso2.com:9443/admin`

Default credentials: `admin` / `admin`

---

## Key Things to Get Right

- **`/etc/hosts` must be set on all VMs** before running Puppet — WSO2 embeds hostnames in internal URLs.
- **DB must be ready first** — WSO2 initializes its schema on first startup.
- **Set the profile fact before requesting the cert** — otherwise Puppet tries to declare an empty class and fails.
- **WSO2 uses `postgre` (not `postgresql`) as the `db_type` value** in `deployment.toml`.
- **Start order matters**: TM → CP → Gateway → KM.
- **If you get "Registered callback does not match" on login**, the CP started with the wrong hostname and registered OAuth apps with stale callback URLs in the DB. Fix: stop all services, drop and recreate the databases, re-run the schema scripts, then restart. The CP will re-register the OAuth apps with the correct hostname on startup.
- **Duplicate `/etc/hosts` entries on your local machine** will cause traffic to go to the wrong IP — macOS uses the first matching entry. Each hostname must appear only once.
- **Bearer tokens require the Gateway to subscribe to the CP's event hub** (JMS on `cp.wso2.com:5672`). If the Gateway can't reach port 5672 on the CP, it won't receive key manager configurations and all OAuth Bearer token invocations will return 900901 "Invalid Credentials". Internal-Key invocations are unaffected. Verify with `nc -zv cp.wso2.com 5672` from the Gateway VM.
