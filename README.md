# Chroncle Installation Script

The script is interactive and requires user input for various parameters like feed name, paths to ETH keystore file and password file, ETH address, and an Ethereum Mainnet RPC endpoint. The script should not be run as root, and a user with sudo permissions is required. If run as root, the script will prompt the user to create a new user.

### Key Steps:
Retrieve and Execute the Installation Script:


```
cd /tmp
wget https://raw.githubusercontent.com/chronicleprotocol/scripts/main/feeds/k3s-install/install.sh 
chmod a+x install.sh
./install.sh
```

### Provide Necessary Information:

- Feed name (e.g., my-feed)
- Path to ETH keystore file and password file
- Corresponding ETH from address
- Ethereum RPC endpoint
- Run the Script:

### Verify Installation:

- Check if pods are running using `kubectl get pods -n <feedname>`.
- View pod logs and verify that the services are created and show the correct External IP.
- Ensure that the EXTERNAL-IP shown for the musig and ghost services matches the server's IP address.

## Install with .env:
The script can also use a `.env` file located in the same directory as install.sh to populate the required input values. Copy [`.env.example`](feeds/k3s-install/.env.example) to `.env`, and update values as needed.

## Manual Installation via Helm:
Installation using Helm, including adding the Helm repository, creating a valid values.yaml file, and installing or upgrading a feed.


> **Notes**
- The script will create Kubernetes secrets used in the Helm release and feed services.
- The user may need to log out and log back in after being added to the sudo group for the group changes to take effect.
- The installation script will print out the feed’s `.onion` address, which needs to be provided to Chronicle for whitelisting.
- The script can be run multiple times with the same values, and it will attempt to run helm upgrade on the feed release with any updated input variables.
- The article also provides information on how to view and verify secrets, services, and other configurations post-installation, and how to manually install or upgrade using Helm with a valid values.yaml file.
