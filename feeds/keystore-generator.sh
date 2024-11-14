#!/bin/bash

# Tool to generate new encrypted keystore with Ethereum address matching
# a specific first byte identifier.
#
# Dependencies:
# - cast, see https://getfoundry.sh
# - unix utilities
#
# Usage:
#
#  $ ./key-generator.sh <0x prefixed byte> <keystore path> <keystore password>
#
# Example:
#
#  $ ./key-generator.sh 0xff ./keystores test
set -euo pipefail # Enable strict mode for bash

# Fail if foundry toolchain's cast not installed.
if ! command -v cast &> /dev/null
then
  echo "Error: Please install the foundry toolchain's cast tool, see https://getfoundry.sh"
fi

# Fail if invalid number of arguments provided.
if [ "$#" -ne 3 ]; then
  echo "Usage: $0 <0x prefixed byte> <keystore path> <keystore password>"
  exit 1
fi

# Store arguments into variables.
assigned_id="$1"
path="$2"
password="$3"

# Fail if invalid arguments provided.
if [ -z "$assigned_id" ] || [ -z "$path" ] || [ -z "$password" ]; then
  echo "Usage: $0 <0x prefixed byte> <keystore path> <keystore password>"
  exit 1
fi

# Note to ensure assigned_id is in lower case.
assigned_id=$(echo "$assigned_id" | tr '[:upper:]' '[:lower:]')

ctr=0
while true; do
    # Create new keystore and catch output.
    output=$(cast wallet new --unsafe-password "$password" "$path")

    # Get path and address of new keystore from output.
    keystore=$(echo "$output" | awk '/Created new encrypted keystore file:/ {print $6}')
    address=$(echo "$output" | awk '/Address:/ {print $2}')

    # Get address' id in lower case.
    id=$(echo "${address:0:4}" | tr '[:upper:]' '[:lower:]')

    # Check whether first byte matches assigned id.
    if [ "$id" == "$assigned_id" ]; then
        # Address suitable, print output and exit.
        echo "Generated new validator address with id=$id. Needed $ctr tries."
        echo "Keystore: $keystore"
        echo "Address: $address"

        exit 0
    else
        # Address not suitable, delete keystore and continue search.
        rm "$keystore"
    fi

    ctr=$((ctr + 1))
done
