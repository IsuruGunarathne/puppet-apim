# Azure Guide: All-in-One WSO2 API Manager with PostgreSQL

This guide sets up a minimal 3-VM deployment on Azure:

| VM | Role | Puppet Profile | Private IP |
|---|---|---|---|
| `puppet-master` | Puppet Master | (not an agent) | 10.6.0.4 |
| `apim` | API Manager (all-in-one) | `apim` | 10.6.0.5 |
| `db` | PostgreSQL database | (not an agent) | 10.6.0.6 |

---

## 1. Create the Azure VMs

Create all VMs in the **same VNet and subnet**.

```bash
az group create --name apim-rg --location eastus

az network vnet create \
  --resource-group apim-rg \
  --name apim-vnet \
  --address-prefix 10.6.0.0/16 \
  --subnet-name apim-subnet \
  --subnet-prefix 10.6.0.0/24

# Puppet Master
az vm create \
  --resource-group apim-rg \
  --name puppet-master \
  --image Ubuntu2204 \
  --vnet-name apim-vnet \
  --subnet apim-subnet \
  --admin-username azureuser \
  --generate-ssh-keys \
  --size Standard_B2s

# APIM node
az vm create \
  --resource-group apim-rg \
  --name apim \
  --image Ubuntu2204 \
  --vnet-name apim-vnet \
  --subnet apim-subnet \
  --admin-username azureuser \
  --generate-ssh-keys \
  --size Standard_D4s_v3

# Database node
az vm create \
  --resource-group apim-rg \
  --name db \
  --image Ubuntu2204 \
  --vnet-name apim-vnet \
  --subnet apim-subnet \
  --admin-username azureuser \
  --generate-ssh-keys \
  --size Standard_D2s_v3
```

Note down the **private IPs** of each VM after creation:
```bash
az vm list-ip-addresses --resource-group apim-rg --output table
```

---

## 2. Open Required Ports (NSG)

| Port | VM | Purpose |
|---|---|---|
| 9443 | apim | Management UI (Publisher, DevPortal, Admin) — public |
| 8280 | apim | HTTP API traffic — public |
| 8243 | apim | HTTPS API traffic — public |
| 8140 | puppet-master | Puppet agent communication — internal only |
| 5432 | db | PostgreSQL — internal only |

```bash
# Allow APIM UI access from the internet
az vm open-ports --resource-group apim-rg --name apim --ports 9443,8280,8243

# Allow Puppet port only within the VNet
az network nsg rule create \
  --resource-group apim-rg \
  --nsg-name puppet-masterNSG \
  --name allow-puppet \
  --priority 100 \
  --source-address-prefixes 10.6.0.0/24 \
  --destination-port-ranges 8140 \
  --protocol Tcp
```

---

## 3. Configure /etc/hosts on All VMs

SSH into each VM and add these entries to `/etc/hosts`:

```bash
sudo tee -a /etc/hosts << 'EOF'
10.6.0.4  puppet puppet-master.apim.local
10.6.0.5  apim apim.wso2.com
10.6.0.6  db db.wso2.com
EOF
```

Do this on **all three VMs**.

---

## 4. Set Up PostgreSQL on the DB VM

SSH into the `db` VM:

```bash
sudo apt update
sudo apt install postgresql postgresql-contrib unzip -y

# Allow connections from the VNet
sudo sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/" \
  /etc/postgresql/*/main/postgresql.conf

echo "host all all 10.6.0.0/24 md5" | sudo tee -a \
  /etc/postgresql/*/main/pg_hba.conf

sudo systemctl restart postgresql

# Create databases and user
sudo -u postgres psql << 'EOF'
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
```

Initialize the WSO2 schema:

```bash
cd ~
wget -O wso2am-4.7.0.zip https://github.com/wso2/product-apim/releases/download/v4.7.0-rc/wso2am-4.7.0-rc.zip
unzip wso2am-4.7.0.zip

# apimgt DB — API Manager specific tables
psql -h localhost -U apimuser -d apimgt -f wso2am-4.7.0/dbscripts/apimgt/postgresql.sql

# shareddb — shared identity/registry tables
psql -h localhost -U apimuser -d shareddb -f wso2am-4.7.0/dbscripts/postgresql.sql

# Clean up
rm -rf wso2am-4.7.0 wso2am-4.7.0.zip
```

---

## 5. Install Puppet Server on the Master VM

SSH into `puppet-master`:

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

---

## 6. Clone This Repo onto the Puppet Master

```bash
cd /etc/puppetlabs/code/environments/
sudo rm -rf production
sudo git clone --single-branch --branch 4.7.test https://github.com/IsuruGunarathne/puppet-apim.git production
```

Update `apim_common/manifests/params.pp` to use JDK 21:

```bash
sudo sed -i "s/amazon-corretto-17.0.6.10.1-linux-x64/amazon-corretto-21.0.5.11.1-linux-x64/" \
  /etc/puppetlabs/code/environments/production/modules/apim_common/manifests/params.pp
```

Download the product pack, JDK, and PostgreSQL JDBC driver:

```bash
# WSO2 API Manager pack
sudo wget -O /etc/puppetlabs/code/environments/production/modules/apim_common/files/packs/wso2am-4.7.0.zip \
  https://github.com/wso2/product-apim/releases/download/v4.7.0-rc/wso2am-4.7.0-rc.zip

# Amazon Corretto 21 (JDK)
sudo wget -O /etc/puppetlabs/code/environments/production/modules/apim_common/files/jdk/amazon-corretto-21.0.5.11.1-linux-x64.tar.gz \
  https://corretto.aws/downloads/resources/21.0.5.11.1/amazon-corretto-21.0.5.11.1-linux-x64.tar.gz

# PostgreSQL JDBC driver
sudo mkdir -p /etc/puppetlabs/code/environments/production/modules/apim/files/repository/components/lib/
sudo wget -O /etc/puppetlabs/code/environments/production/modules/apim/files/repository/components/lib/postgresql-42.7.3.jar \
  https://jdbc.postgresql.org/download/postgresql-42.7.3.jar
```

---

## 7. Configure params.pp for the apim Profile

Edit `/etc/puppetlabs/code/environments/production/modules/apim/manifests/params.pp`:

```puppet
class apim::params inherits apim_common::params {
  $start_script_template = 'bin/api-manager.sh'
  $jvmxms = '256m'
  $jvmxmx = '2048m'

  $template_list = [
    'repository/conf/deployment.toml'
  ]

  # Copy the PostgreSQL JDBC driver into the product lib directory
  $file_list = [
    'repository/components/lib/postgresql-42.7.3.jar'
  ]

  $file_removelist = []

  $hostname = 'apim.wso2.com'

  # PostgreSQL database config
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

  $oauth_configs_revoke_api_url        = 'https://apim.wso2.com:${https.nio.port}/revoke'
  $throttle_config_policy_deployer_url = 'https://apim.wso2.com:${mgt.transport.https.port}${carbon.context}services/'
}
```

---

## 8. Install Puppet Agent on the APIM VM

SSH into the `apim` VM:

```bash
wget -O puppet8.deb https://apt.puppet.com/puppet8-release-jammy.deb
sudo dpkg -i puppet8.deb
sudo apt update
sudo apt install puppet-agent -y

sudo bash -c 'cat >> /etc/puppetlabs/puppet/puppet.conf << EOF
[main]
certname = apim.apim.local
server = puppet-master.apim.local
[agent]
environment = production
EOF'
```

---

## 9. Sign the Certificate and Apply

On the `apim` VM, set the profile fact first, then request a cert:

```bash
sudo mkdir -p /etc/puppetlabs/facter/facts.d
echo "profile=apim" | sudo tee /etc/puppetlabs/facter/facts.d/profile.txt
sudo /opt/puppetlabs/bin/puppet agent --test --waitforcert 300
```

On the `puppet-master`, sign it (within 5 minutes):

```bash
sudo /opt/puppetlabs/bin/puppetserver ca sign --all
```

The `apim` VM will automatically apply the catalog once the cert is signed. Puppet will extract the product pack, write `deployment.toml`, copy the JDBC driver, register a systemd service, and start WSO2 API Manager.

---

## 10. Verify

```bash
# On the apim VM, check the service
sudo systemctl status wso2apim

# Tail the logs
tail -f /mnt/apim/wso2am-4.7.0/repository/logs/wso2carbon.log
```

On **your local machine**, add the APIM public IP to `/etc/hosts`:

```
<apim-public-ip>  apim.wso2.com
```

Then access:
- **Publisher**: `https://apim.wso2.com:9443/publisher`
- **Developer Portal**: `https://apim.wso2.com:9443/devportal`
- **Admin**: `https://apim.wso2.com:9443/admin`

Default credentials: `admin` / `admin`

---

## Key Things to Get Right

- **DB must be ready before running Puppet on the APIM VM.** WSO2 creates its schema on first startup — if the DB is unreachable, startup fails.
- **The PostgreSQL JDBC driver must be in `repository/components/lib/`** before the server starts. Puppet handles this via `$file_list`.
- **WSO2 uses `postgre` (not `postgresql`) as the `db_type` value** in `deployment.toml`.
- **`/etc/hosts` must be consistent across all VMs** — WSO2 uses the configured `hostname` for internal URL generation.
- **Set the profile fact before running the Puppet agent** — otherwise Puppet tries to declare an empty class and fails.
