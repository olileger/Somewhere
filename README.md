# Somewhere
Somewhere is a WireGuard VPN within a lightweight Linux VM.

## Quick Notes
- The service is deployable to any Azure region, you'll be prompted to select a region during the deployment script execution.
- The service is designed to be cost-effective, with an estimated monthly cost of around 5€, depending on the Azure region and usage.
    * VM tier is B1ls, which is a low-cost option suitable for light workloads like a personal VPN server.
    * Disk size is Standard HDD S4 (32GB)
    * Running on 24x7 is around 4.5€ per month in most region
    * The auto shutdown feature helps reduce costs
- Auto shutdown is configured for the VM to help minimize costs when the service is not in use.
    * By default, the VM will shut down at 23:30 AM UTC every day.
    * You can adjust the auto shutdown settings in the Azure portal if needed.


## Install
Installation is in 3 steps:

### 1. Clone the repository and run the script to deploy the service.
Login to your Azure portal and open the Cloud Shell in bash mode. Then run the following commands to clone the repository and execute the deployment script:
```
git clone https://github.com/olileger/Somewhere.git

bash ./Somewhere/run.sh
```

### 2. Keep the client configuration output from the script.
Then copy/paste this output of the script to a new `client.conf` file:
```
[Interface]
PrivateKey = <configured private key>
Address = <configured IP address>
DNS = <configured DNS server>

[Peer]
PublicKey = <key>
Endpoint = <configured endpoint>
AllowedIPs = <configured allowed IPs>
PersistentKeepalive = <configured keepalive>
```

### 3. Import the `client.conf` file into your WireGuard client.
Open the WireGuard client on your device and import the `client.conf` file you created in step 2.
This will allow you to connect to the Somewhere VPN service.


## Prerequisites
- An Azure subscription with permissions to create resources.
- A WireGuard client installed on your device to connect to the VPN service.

## Uninstall
- Azure: delete the `somewhere` resource group in your Azure portal.
- WireGuard client: delete the imported `client` configuration from your WireGuard client.