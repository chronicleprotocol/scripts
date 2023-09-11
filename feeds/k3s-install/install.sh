#!/bin/bash

set -euo pipefail

display_usage() {
    echo "Usage:"
    echo "======"
    echo "./install.sh"
    echo "# follow the prompts"
    echo "required: feed name, ethereum rpc url, ethereum address, ethereum keystore file, ethereum password file"
}

function _preflight {
	if command -v lsb_release; then
		# Check the operating system version
		os_version=$(lsb_release -rs)
	else
		os_version=""
	fi

  # Check if the operating system is Ubuntu 22.04
  if [ "$os_version" != "22.04" ]; then
      echo "[WARNING]: This script is designed for Ubuntu 22.04 and may not work correctly on your system!"
  fi

  # Check if the user is root
  if [ "$USER" == "root" ]; then
      echo "[WARNING]: This script should not be run as root. I will attempt to create a new user called **chronicle**"
      echo "[INFO]:..........creating chronicle user........."
      create_user
      echo "[INFO]:..........switch to the chronicle user........."
      echo "[INFO]:..........su chronicle........"
      exit 1
  fi
}

function create_user {
    # Create the user with no password
    useradd -m -s /bin/bash chronicle
    passwd -d chronicle

    # Add the user to the sudoers group
    usermod -aG sudo chronicle

    echo "[NOTICE]: User chronicle created with no password and added to the sudoers group."
}

function install_deps {
    sudo apt-get update -y || echo "[ERROR]: apt-get update failed"

    #check if jq exists
    command -v jq
    jq_check=$?

    if [ "$jq_check" -eq 0 ]; then
        echo "[INFO]: *** jq is already installed ***"
        command jq --version
    elseif sudo apt-get update -y; then
        sudo apt-get install jq -y
        echo "[SUCCESS]: jq is now installed !!!"
        command jq --version
		else
			echo "[ERROR]: jq installation failed"
		fi


    #check if helm exists
    command -v helm
    helm_check=$?

    if [ "$helm_check" -eq 0 ]; then
        echo "[INFO]: *** helm is already installed ***"
        command helm version
    else
        curl -sfL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
        echo "[SUCCESS]: helm is now installed !!!"
        command helm version
    fi


    # check if k3s is installed:
    command -v k3s
    k3s_check=$?

    if [ "$k3s_check" -eq 0 ]; then
        echo "INFO: *** k3s is already installed ***"
        command k3s -v
    else
        curl -sfL https://get.k3s.io | sh -
        mkdir /home/$USER/.kube
        sudo cp /etc/rancher/k3s/k3s.yaml /home/$USER/.kube/config
        sudo chown chronicle:chronicle /home/$USER/.kube/config
        sudo chmod 600 /home/$USER/.kube/config

        # Add KUBECONFIG environment variable to .bashrc
        echo "export KUBECONFIG=/home/$USER/.kube/config ">> /home/$USER/.bashrc
        # shellcheck disable=SC1091
        source "/home/$USER/.bashrc"
        echo "[SUCCESS]: k3s is now installed !!!"
        command k3s -v
    fi

    # check if keeman is installed:
    command -v keeman
    keeman_check=$?

    if [ "$keeman_check" -eq 0 ]; then
        echo "[INFO]: *** keeman is already installed ***"
    else
        wget https://github.com/chronicleprotocol/keeman/releases/download/v0.4.1/keeman_0.4.1_linux_amd64.tar.gz -O - | tar -xz
        sudo mv keeman /usr/local/bin
    fi
}

function create_namespace {
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    kubectl create namespace $FEED_NAME
}


function create_eth_secret {
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    ETH_PASS_FILEContent=$(sudo cat $ETH_PASS_FILE)
    sudo cp $ETH_KEY_FILE /home/$USER/$FEED_NAME/keystore.json
    kubectl create secret generic $FEED_NAME-eth-keys \
    --from-file=ethKeyStore=/home/$USER/$FEED_NAME/keystore.json \
    --from-literal=ethFrom=$ETH_FROM_ADDR \
    --from-literal=ETH_PASS_FILE=$ETH_PASS_FILEContent \
    --namespace $FEED_NAME
}


function create_tor_secret {
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    keeman gen | tee >(cat >&2) | keeman derive -f onion > torkeys.json
    kubectl create secret generic $FEED_NAME-tor-keys \
        --from-literal=hostname="$(jq -r '.hostname' < torkeys.json)" \
        --from-literal=hs_ed25519_secret_key="$(jq -r '.secret_key' < torkeys.json)" \
        --from-literal=hs_ed25519_public_key="$(jq -r '.public_key' < torkeys.json)" \
        --namespace $FEED_NAME

		echo "-----------------------------------------------------------------------------------------------------"
		echo "This is your .onion address:"
		echo "$(jq -r '.hostname' < torkeys.json)"
		echo "-----------------------------------------------------------------------------------------------------"

}


function create_helm_release {
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    helm repo add chronicle https://chronicleprotocol.github.io/charts/
    helm repo update
    helm install "$FEED_NAME" -f /home/$USER/"$FEED_NAME"/generated-values.yaml  chronicle/feed --namespace "$FEED_NAME"
}


function collect_vars {
    # Prompt the user for values

		if [[ -z ${FEED_NAME:-} ]]; then
			echo ">> Enter feed name (eg chronicle-feed):"
			read -r FEED_NAME
			declare -g FEED_NAME=$FEED_NAME
		fi

		if [[ -z ${ETH_RPC_URL:-} ]]; then
			echo ">> Enter the Ethereum RPC URL:"
			read -r ETH_RPC_URL
    fi

		if [[ -z ${ETH_FROM_ADDR:-} ]]; then
			echo ">> Enter your ETH Address (eg: 0x3a...):"
			read -r ETH_FROM_ADDR
			declare -g ETH_FROM_ADDR=$ETH_FROM_ADDR
		fi

		if [[ -z ${ETH_KEY_FILE:-} ]]; then
			echo ">> Enter the path to your ETH keystore (eg: /path/to/keystore.json):"
			read -r ETH_KEY_FILE
			declare -g ETH_KEY_FILE=$ETH_KEY_FILE
		fi

		if [[ -z ${ETH_PASS_FILE:-} ]]; then
			echo ">> Enter the path to your ETH password file (eg: /path/to/password.txt):"
			read -r ETH_PASS_FILE
			declare -g ETH_PASS_FILE=$ETH_PASS_FILE
		fi

    sudo mkdir -p /opt/chronicle/"$FEED_NAME"
    cd /opt/chronicle/"$FEED_NAME" || { echo "[ERROR]: directory not found"; exit 1; }

    # Generate the values.yaml file
    cat <<EOF > /opt/chronicle/"${FEED_NAME}"/generated-values.yaml
ghost:
  ethConfig:
    ethFrom:
      existingSecret: '$FEED_NAME-eth-keys'
      key: "ethFrom"
    ethKeys:
      existingSecret: '$FEED_NAME-eth-keys'
      key: "ethKeyStore"
    ETH_PASS_FILE:
      existingSecret: '$FEED_NAME-eth-keys'
      key: "ETH_PASS_FILE"

  # ethereum RPC client
  ETH_RPC_URL: "$ETH_RPC_URL"
  ethChainId: 1

  # default RPC client
  rpcUrl: "$ETH_RPC_URL"
  chainId: 1

musig:
  ethConfig:
    ethFrom:
      existingSecret: '$FEED_NAME-eth-keys'
      key: "ethFrom"
    ethKeys:
      existingSecret: '$FEED_NAME-eth-keys'
      key: "ethKeyStore"
    ETH_PASS_FILE:
      existingSecret: '$FEED_NAME-eth-keys'
      key: "ETH_PASS_FILE"

  ETH_RPC_URL: "$ETH_RPC_URL"
  ethChainId: 1

tor-proxy:
    torConfig:
      existingSecret: '$FEED_NAME-tor-keys'
EOF
    echo "You need to install the helm chart with the following command:"
    echo "-----------------------------------------------------------------------------------------------------"
    # shellcheck disable=SC2086,SC2027
    echo "|   helm install "$FEED_NAME" -f /home/$USER/"$FEED_NAME"/generated-values.yaml  chronicle/feed --namespace "$FEED_NAME"            |"
    echo "-----------------------------------------------------------------------------------------------------"
}

echo "[INFO]:..........running preflight checks........."
_preflight

echo "[INFO]:..........installing dependencies........."
install_deps

echo "[INFO]:..........gather input variables........."
collect_vars

echo "[INFO]:..........installing k8s chronicle stack.........."
echo "[INFO]:..........create namespace $FEED_NAME.........."
create_namespace

echo "[INFO]:..........create secret with ETH keys.........."
create_eth_secret

echo "[INFO]:..........create secret with TOR keys.........."
create_tor_secret

echo "[INFO]:..........create helme release.........."
create_helm_release

echo "[NOTICE]: setup complete!"
