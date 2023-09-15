#!/bin/bash

display_usage() {
    echo "Usage:"
    echo "======"
    echo "./install.sh"
    echo "# follow the prompts"
    echo "required: feed name, ethereum rpc url, ethereum address, ethereum keystore file, ethereum password file"
}

function _preflight {
  # Check the operating system version
  os_version=$(lsb_release -rs)

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
      # exit 1
  fi
}

function create_user {
    # Create the user with no password
    sudo useradd -m -s /bin/bash chronicle
    sudo passwd -d chronicle

    # Add the user to the sudoers group
    sudo usermod -aG sudo chronicle

    echo "[NOTICE]: User chronicle created with no password and added to the sudoers group."
}

function install_deps {
    sudo apt-get update -y

    #check if jq exists
    command -v jq
    jq_check=$?

    if [ "$jq_check" -eq 0 ]; then
        echo "[INFO]: *** jq is already installed ***"
        command jq --version
    else
        sudo apt-get install jq -y
        echo "[SUCCESS]: jq is now installed !!!"
        command jq --version
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
        mkdir /home/chronicle/.kube
        sudo cp /etc/rancher/k3s/k3s.yaml /home/chronicle/.kube/config
        sudo chown chronicle:chronicle -R /home/chronicle/.kube
        sudo chmod 600 /home/chronicle/.kube/config
        
        # Add KUBECONFIG environment variable to .bashrc
        echo "export KUBECONFIG=/home/chronicle/.kube/config ">> /home/chronicle/.bashrc
        # shellcheck disable=SC1091
        source "/home/chronicle/.bashrc"
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
    if [ $(id -u) -eq 0 ]; then
      export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    else
      export KUBECONFIG=$HOME/.kube/config 
    fi
    kubectl create namespace $feedName
}


function create_eth_secret {
    if [ $(id -u) -eq 0 ]; then
      export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    else
      export KUBECONFIG=$HOME/.kube/config 
    fi
	  ethPassContent=$(sudo cat $ethPass)
    sudo cp $keyStoreFile /home/chronicle/$feedName/keystore.json 
	  sudo chown chronicle:chronicle -R /home/chronicle/$feedName
    kubectl create secret generic $feedName-eth-keys \
    --from-file=ethKeyStore=/home/chronicle/$feedName/keystore.json \
    --from-literal=ethFrom=$ethAddress \
    --from-literal=ethPass=$ethPassContent \
    --namespace $feedName

	echo "-----------------------------------------------------------------------------------------------------"
	echo "This is your Feed address:"
	echo "$ethAddress"
	echo "-----------------------------------------------------------------------------------------------------"
}


function create_tor_secret {
    if [ $(id -u) -eq 0 ]; then
      export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    else
      export KUBECONFIG=$HOME/.kube/config 
    fi
    keeman gen | tee >(cat >&2) | keeman derive -f onion > /home/chronicle/$feedName/torkeys.json
	  sudo chown chronicle:chronicle -R /home/chronicle/$feedName
    kubectl create secret generic $feedName-tor-keys \
        --from-literal=hostname="$(jq -r '.hostname' < /home/chronicle/$feedName/torkeys.json)" \
        --from-literal=hs_ed25519_secret_key="$(jq -r '.secret_key' < /home/chronicle/$feedName/torkeys.json)" \
        --from-literal=hs_ed25519_public_key="$(jq -r '.public_key' < /home/chronicle/$feedName/torkeys.json)" \
        --namespace $feedName
	echo "-----------------------------------------------------------------------------------------------------"
	echo "This is your .onion address:"
	echo "$(jq -r '.hostname' < /home/chronicle/$feedName/torkeys.json)"
	echo "-----------------------------------------------------------------------------------------------------"
}


function create_helm_release {
    if [ $(id -u) -eq 0 ]; then
      export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    else
      export KUBECONFIG=$HOME/.kube/config 
    fi
    helm repo add chronicle https://chronicleprotocol.github.io/charts/
    helm repo update
    helm install "$feedName" -f /home/chronicle/"$feedName"/generated-values.yaml  chronicle/feed --namespace "$feedName"
}


function collect_vars {
    # Prompt the user for values
    echo ">> Enter feed name (eg chronicle-feed):"
    read -r feedName
    declare -g feedName=$feedName

    echo ">> Enter the Ethereum RPC URL:"
    read -r ethRpcUrl

    echo ">> Enter your ETH Address (eg: 0x3a...):"
    read -r ethAddress
    declare -g ethAddress=$ethAddress

    echo ">> Enter the path to your ETH keystore (eg: /path/to/keystore.json):"
    read -r keyStoreFile
    declare -g keyStoreFile=$keyStoreFile

    echo ">> Enter the path to your ETH password file (eg: /path/to/password.txt):"
    read -r ethPass
    declare -g ethPass=$ethPass

    mkdir -p /home/chronicle/"$feedName"
    cd /home/chronicle/"$feedName" || { echo "[ERROR]: directory not found"; exit 1; }

    # Generate the values.yaml file
    cat <<EOF > /home/chronicle/"${feedName}"/generated-values.yaml
ghost:
  ethConfig:
    ethFrom:
      existingSecret: '$feedName-eth-keys'
      key: "ethFrom"
    ethKeys:
      existingSecret: '$feedName-eth-keys'
      key: "ethKeyStore"
    ethPass:
      existingSecret: '$feedName-eth-keys'
      key: "ethPass"

  # ethereum RPC client
  ethRpcUrl: "$ethRpcUrl"
  ethChainId: 1

  # default RPC client
  rpcUrl: "$ethRpcUrl"
  chainId: 1

musig:
  ethConfig:
    ethFrom:
      existingSecret: '$feedName-eth-keys'
      key: "ethFrom"
    ethKeys:
      existingSecret: '$feedName-eth-keys'
      key: "ethKeyStore"
    ethPass:
      existingSecret: '$feedName-eth-keys'
      key: "ethPass"

  ethRpcUrl: "$ethRpcUrl"
  ethChainId: 1

tor-proxy:
  torConfig:
    existingSecret: '$feedName-tor-keys'
EOF
    echo "You need to install the helm chart with the following command:"
    echo "-------------------------------------------------------------------------------------------------------------------------------"
    # shellcheck disable=SC2086,SC2027
    echo "|   helm install "$feedName" -f /home/chronicle/"$feedName"/generated-values.yaml  chronicle/feed --namespace "$feedName"       |"
    echo "-------------------------------------------------------------------------------------------------------------------------------"
}

echo "[INFO]:..........running preflight checks........."
_preflight

echo "[INFO]:..........installing dependencies........."
install_deps

echo "[INFO]:..........gather input variables........."
collect_vars

echo "[INFO]:..........installing k8s chronicle stack.........."
echo "[INFO]:..........create namespace $feedName.........."
create_namespace

echo "[INFO]:..........create secret with ETH keys.........."
create_eth_secret

echo "[INFO]:..........create secret with TOR keys.........."
create_tor_secret

echo "[INFO]:..........create helme release.........."
create_helm_release


echo "[NOTICE]: setup complete!"