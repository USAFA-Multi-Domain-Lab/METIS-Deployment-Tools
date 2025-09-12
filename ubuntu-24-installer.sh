#!/bin/bash

# METIS Provisioning Script for Ubuntu
# This script automates the installation based on the METIS setup instructions.

set -e

# Colors for output
green='\e[32m'
red='\e[31m'
yellow='\e[33m'
reset='\e[0m'

#Default directory
METIS_INSTALL_DIR="/opt/metis"

echo -e "${green}[METIS] Starting installation and provisioning...${reset}"

# Generate random usernames and passwords (exclude double quotes)
ADMIN_USER="admin_$(openssl rand -hex 4 | tr -d '"')"
ADMIN_PASS="$(openssl rand -base64 16 | tr -d '"')"
METIS_USER="metis_$(openssl rand -hex 4 | tr -d '"')"
METIS_PASS="$(openssl rand -base64 16 | tr -d '"')"
CREDENTIALS_FILE="/root/.metis-credentials.txt"
CREDENTIALS_EXIST=false

# There's a possibility of MongoDB already being installed
# with auth enabled. This checks for that condition.
auth_check="$(mongosh --quiet --eval "db.getSiblingDB('admin').system.users.find()" 2>/dev/null || true)"

# Load or generate credentials
if [ -f "$CREDENTIALS_FILE" ]; then
  echo -e "${yellow}[METIS] Existing credentials found at $CREDENTIALS_FILE. Loading...${reset}"
  ADMIN_USER=$(grep 'MongoDB Admin Username:' "$CREDENTIALS_FILE" | awk -F': ' '{print $2}')
  ADMIN_PASS=$(grep 'MongoDB Admin Password:' "$CREDENTIALS_FILE" | awk -F': ' '{print $2}')
  METIS_USER=$(grep 'MongoDB Web Username:' "$CREDENTIALS_FILE" | awk -F': ' '{print $2}')
  METIS_PASS=$(grep 'MongoDB Web Password:' "$CREDENTIALS_FILE" | awk -F': ' '{print $2}')
  CREDENTIALS_EXIST=true
# Handle case where MongoDB was installed prior
# to METIS installation.
elif [[ "$auth_check" == *MongoServerError* ]]; then
  # Check if an admin user already exists in MongoDB
  echo -e "${yellow}[METIS] An existing MongoDB instance with auth enabled. In order to install METIS, a dedicated DB user is needed in order for the web server to connect to the database. Please enter the credentials for the existing admin user to proceed.${reset}"
  read -p "Enter existing MongoDB admin username: " ADMIN_USER
  read -s -p "Enter existing MongoDB admin password: " ADMIN_PASS
fi

# Save credentials to a root-only file
save_credentials() {
  # Skip saving if credentials already exist.
  if [ "$CREDENTIALS_EXIST" = true ]; then
    echo -e "${yellow}[METIS] Credentials already exist. Skipping save.${reset}"
    return
  fi

  sudo bash -c "cat > $CREDENTIALS_FILE" <<EOF
MongoDB Admin Username: $ADMIN_USER
MongoDB Admin Password: $ADMIN_PASS
MongoDB Web Username: $METIS_USER
MongoDB Web Password: $METIS_PASS
EOF
  sudo chmod 600 $CREDENTIALS_FILE
  echo -e "${green}[METIS] Credentials saved to $CREDENTIALS_FILE (root only).${reset}"
}

# Database Server Setup -- based on: https://www.mongodb.com/docs/manual/tutorial/install-mongodb-on-ubuntu/
install_mongodb() {
  echo -e "${green}[METIS] Installing MongoDB...${reset}"

  sudo apt-get update
  sudo apt-get install -y gnupg curl git

  # Setup keys/sources
  if [ ! -f /usr/share/keyrings/mongodb-server-8.0.gpg ]; then
    curl -fsSL https://www.mongodb.org/static/pgp/server-8.0.asc | \
      sudo gpg --batch --yes -o /usr/share/keyrings/mongodb-server-8.0.gpg --dearmor
  else
    echo "GPG key already exists: /usr/share/keyrings/mongodb-server-8.0.gpg"
  fi

  echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-8.0.gpg ] https://repo.mongodb.org/apt/ubuntu noble/mongodb-org/8.0 multiverse" | \
    sudo tee /etc/apt/sources.list.d/mongodb-org-8.0.list > /dev/null
  sudo apt-get update

  # Install MongoDB Community Server
  sudo apt-get install -y mongodb-org=8.0.4 mongodb-org-database=8.0.4 mongodb-org-server=8.0.4 mongodb-mongosh mongodb-org-mongos=8.0.4 mongodb-org-tools=8.0.4

  # Prevent automatic updates
  echo "mongodb-org hold" | sudo dpkg --set-selections
  echo "mongodb-org-database hold" | sudo dpkg --set-selections
  echo "mongodb-org-server hold" | sudo dpkg --set-selections
  echo "mongodb-mongosh hold" | sudo dpkg --set-selections
  echo "mongodb-org-mongos hold" | sudo dpkg --set-selections
  echo "mongodb-org-tools hold" | sudo dpkg --set-selections

  echo -e "${green}[METIS] MongoDB installed.${reset}"
}

configure_mongodb() {
  echo -e "${green}[METIS] Configuring MongoDB...${reset}"
  config_file="/etc/mongod.conf"

  # Ensure the MongoDB configuration file exists
  if [ ! -f "$config_file" ]; then
    echo -e "${red}[METIS][ERROR] MongoDB configuration file not found: $config_file.${reset}"
    exit 1
  fi

  # Update the bindIp to allow external connections
  if grep -q "^  bindIp: 127.0.0.1" "$config_file"; then
    sudo sed -i 's/^  bindIp: 127.0.0.1/  bindIp: 0.0.0.0/' "$config_file"
    echo -e "${green}[METIS] Updated bindIp to 0.0.0.0 in mongod.conf.${reset}"
  else
    echo -e "${yellow}[METIS][WARN] bindIp is already set to 0.0.0.0 or missing.${reset}"
  fi

  # Handle security block configuration
  if grep -q "^#security:" "$config_file"; then
    # Uncomment the security block and add authorization
    sudo sed -i 's/^#security:.*/security:\n  authorization: enabled/' "$config_file"
    echo -e "${green}[METIS] Uncommented and updated 'security' configuration in mongod.conf.${reset}"
  elif grep -q "^security:" "$config_file"; then
    # Ensure authorization is enabled under the existing security block
    if ! grep -q "^  authorization: enabled" "$config_file"; then
      sudo sed -i '/^security:/a \  authorization: enabled' "$config_file"
      echo -e "${green}[METIS] Added 'authorization: enabled' under existing 'security' configuration.${reset}"
    else
      echo -e "${yellow}[METIS][WARN] 'authorization: enabled' is already set in mongod.conf.${reset}"
    fi
  else
    # Append the security block if it doesn't exist
    echo -e "\nsecurity:\n  authorization: enabled" | sudo tee -a "$config_file" > /dev/null
    echo -e "${green}[METIS] Added 'security' block to mongod.conf.${reset}"
  fi

  # Restart MongoDB to apply changes
  echo -e "${green}[METIS] Restarting MongoDB to apply configuration changes...${reset}"
  sudo systemctl enable mongod
  sudo systemctl restart mongod
  echo -e "${green}[METIS] MongoDB configured and restarted.${reset}"
}


check_install_mongodb() {
  echo -e "${green}[METIS] Checking MongoDB installation...${reset}"

  # Check if data and log directories exist
  if [[ -d "/var/lib/mongodb" && -d "/var/log/mongodb" ]]; then
    echo -e "${green}[METIS] MongoDB directories found.${reset}"
  else
    echo -e "${red}[METIS] MongoDB directories not found. Installation might be incomplete.${reset}"
    exit 1
  fi

  # Verify configuration
  config_file="/etc/mongod.conf"
  if grep -q "bindIp: 0.0.0.0" "$config_file"; then
    echo -e "${green}[METIS] MongoDB configuration verified.${reset}"
  else
    echo -e "${red}[METIS] MongoDB configuration update failed. Please check $config_file.${reset}"
    exit 1
  fi

  # Check MongoDB binary presence and execute health check
  if ! command -v mongod &>/dev/null; then
    echo -e "${red}[METIS] MongoDB binary not found. Installation might be incomplete.${reset}"
    exit 1
  fi

  # Check MongoDB version (handles crashes like "Illegal instruction")
  version_check=$(mongod --version 2>&1 || true)
  if [[ $version_check == *"Illegal instruction"* ]]; then
    echo -e "${red}[METIS] MongoDB version check failed: Illegal instruction.${reset}"
    exit 1
  elif [[ $version_check == *"db version"* ]]; then
    echo -e "${green}[METIS] MongoDB version: $(echo "$version_check" | head -n 1).${reset}"
  else
    echo -e "${red}[METIS] MongoDB version check failed. Output: $version_check${reset}"
    exit 1
  fi

  # Check if MongoDB service is running
  if sudo systemctl is-active --quiet mongod; then
    echo -e "${green}[METIS] MongoDB service is running.${reset}"
  else
    echo -e "${red}[METIS] MongoDB service is not running. Check logs for errors.${reset}"
    # exit 1
  fi
}


setup_mongodb_auth() {
  echo -e "${green}[METIS] Setting up MongoDB authentication...${reset}"

  # Wait for MongoDB to become fully operational
  echo -e "${green}[METIS] Waiting for MongoDB to start...${reset}"
  for i in {1..5}; do
    sleep 3
    if mongosh --eval "db.runCommand({ connectionStatus: 1 })" &>/dev/null; then
      echo -e "${green}[METIS] MongoDB is operational.${reset}"
      break
    fi
    if [ $i -eq 5 ]; then
      echo -e "${red}[METIS][ERROR] MongoDB failed to start. Exiting.${reset}"
      exit 1
    fi
    echo -e "${yellow}[METIS][WARN] MongoDB is not ready. Retrying in 10 seconds...${reset}"
    sleep 7 # + 3 next iteration = 10 seconds.
  done

  if [ "$CREDENTIALS_EXIST" = true ]; then
    echo -e "${yellow}[METIS] Skipping admin user creation; admin user already exist.${reset}"
    return
  fi

  # Always attempt to create admin user (username is random)
  create_admin_output=$(mongosh <<EOF
use admin
db.createUser({
  user: "$ADMIN_USER",
  pwd: "$ADMIN_PASS",
  roles: [
    { role: "userAdminAnyDatabase", db: "admin" },
    { role: "readWriteAnyDatabase", db: "admin" }
  ]
})
EOF
)
  if [[ "$create_admin_output" == *"MongoServerError"* ]]; then
    echo -e "${red}[METIS][ERROR] Failed to create admin user. MongoDB error detected:${reset}"
    echo "$create_admin_output"
    exit 1
  fi

  echo -e "${green}[METIS] Admin user created successfully.${reset}"

  # Restart MongoDB to apply authentication settings
  echo -e "${green}[METIS] Restarting MongoDB to apply security settings...${reset}"
  sudo systemctl restart mongod
  echo -e "${green}[METIS] MongoDB authentication setup completed.${reset}"
}

create_web_user() {
  echo -e "${green}[METIS] Creating web server user...${reset}"

  # Wait for MongoDB to become fully operational
  echo -e "${green}[METIS] Waiting for MongoDB to start...${reset}"
  for i in {1..5}; do
    sleep 3
    if mongosh -u "$ADMIN_USER" -p "$ADMIN_PASS" --authenticationDatabase admin --eval "db.runCommand({ connectionStatus: 1 })" &>/dev/null; then
      echo -e "${green}[METIS] MongoDB is operational.${reset}"
      break
    fi
    if [ $i -eq 5 ]; then
      echo -e "${red}[METIS][ERROR] MongoDB failed to start. Exiting.${reset}"
      exit 1
    fi
    echo -e "${yellow}[METIS][WARN] MongoDB is not ready for web user creation. Retrying in 10 seconds...${reset}"
    sleep 7 # + 3 next iteration = 10 seconds.
  done

  if [ "$CREDENTIALS_EXIST" = true ]; then
    echo -e "${yellow}[METIS] Skipping web server user creation; web server user already exist.${reset}"
    return
  fi

  # Always attempt to create web server user (username is random)
  create_web_output=$(mongosh -u "$ADMIN_USER" -p "$ADMIN_PASS" --authenticationDatabase admin <<EOF
use metis
db.createUser({
  user: "$METIS_USER",
  pwd: "$METIS_PASS",
  roles: [ { role: "readWrite", db: "metis" } ]
})
EOF
)
  if [[ "$create_web_output" == *"MongoServerError"* ]]; then
    echo -e "${red}[METIS][ERROR] Failed to create web server user. MongoDB error detected:${reset}"
    echo "$create_web_output"
    exit 1
  fi

  echo -e "${green}[METIS] Web server user created successfully.${reset}"
}

# Web Server Setup
install_nodejs() {
  echo -e "${green}[METIS] Installing NodeJS...${reset}"
  curl -sL https://deb.nodesource.com/setup_20.x | sudo -E bash -
  sudo apt install -y nodejs
  echo -e "${green}[METIS] NodeJS installed.${reset}"
}

setup_metis() {
  echo -e "${green}[METIS] Setting up METIS...${reset}"

  if [ -d "$METIS_INSTALL_DIR" ]; then
    echo -e "${yellow}[METIS][WARN] Existing METIS installation detected in $METIS_INSTALL_DIR. Skipping clone...${reset}"

    # Set directory permissions for all users
    echo -e "${green}[METIS] Setting permissions for $METIS_INSTALL_DIR...${reset}"
    sudo chmod -R 755 "$METIS_INSTALL_DIR"
    sudo chown -R $USER:$USER "$METIS_INSTALL_DIR"

    cd "$METIS_INSTALL_DIR" || exit 1
  else

    # Set directory permissions for all users
    sudo mkdir -p "$METIS_INSTALL_DIR"
    echo -e "${green}[METIS] Setting permissions for $METIS_INSTALL_DIR...${reset}"
    sudo chmod -R 755 "$METIS_INSTALL_DIR"
    sudo chown -R $USER:$USER "$METIS_INSTALL_DIR"

    # Check SSH key permissions
    sudo chmod 600 /home/admin/.ssh/id_ed25519

    # Add SSH keys.
    eval "$(ssh-agent -s)"
    ssh-add /home/admin/.ssh/id_ed25519

    # Ensure Git does not prompt for confirmation of the host key
    export GIT_SSH_COMMAND='ssh -o StrictHostKeyChecking=no'

    # Clone the repository if it doesn't exist
    echo -e "${green}[METIS] Cloning METIS repository to $METIS_INSTALL_DIR...${reset}"
    git clone git@github.com:salient-usafa-cyber-crew/metis.git "$METIS_INSTALL_DIR" || {
      echo "[ERROR] Failed to clone repository" >&2
      exit 1
    }

    cd "$METIS_INSTALL_DIR" || exit 1
  fi

  # Make cli.sh executable and symlink to /usr/local/bin/metis
  if [ -f "$METIS_INSTALL_DIR/cli.sh" ]; then
    sudo chmod +x "$METIS_INSTALL_DIR/cli.sh"
    sudo ln -sf "$METIS_INSTALL_DIR/cli.sh" /usr/local/bin/metis
    echo -e "${green}[METIS] CLI installed as 'metis' in PATH.${reset}"
  fi

  # Install dependencies and build the application
  echo -e "${green}[METIS] Installing dependencies and building the application...${reset}"
  npm install
  npm run build

  echo -e "${green}[METIS] METIS setup completed.${reset}"
}

configure_metis_env() {
  echo -e "${green}[METIS] Configuring METIS environment...${reset}"
  CONFIG_DIR="$METIS_INSTALL_DIR/config"
  PROD_ENV_FILE="$CONFIG_DIR/prod.env"
  cat <<EOF > "$PROD_ENV_FILE"
MONGO_USERNAME="$METIS_USER"
MONGO_PASSWORD="$METIS_PASS"
EOF
  chmod 600 "$PROD_ENV_FILE"
  echo -e "${green}[METIS] Environment configuration saved to $PROD_ENV_FILE.${reset}"
}

run_metis() {
  echo -e "${green}[METIS] Starting METIS...${reset}"
  cd "$METIS_INSTALL_DIR" || exit 1
  npm run prod
}

create_metis_service() {
  echo -e "${green}[METIS] Creating systemd service for METIS...${reset}"
  sudo bash -c "cat > /etc/systemd/system/metis.service" <<EOL
[Unit]
Description=METIS Web Service
After=network.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$METIS_INSTALL_DIR
ExecStart=/usr/bin/npm run prod
Restart=on-failure
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
EOL
  sudo systemctl daemon-reload
  sudo systemctl enable metis.service
  echo -e "${green}[METIS] METIS service created and enabled to start on boot.${reset}"
}

start_metis_service() {
  echo -e "${green}[METIS] Starting METIS service...${reset}"
  sudo systemctl start metis.service
  sudo systemctl status metis.service --no-pager
}

stop_metis_service() {
  echo -e "${green}[METIS] Stopping METIS service...${reset}"
  sudo systemctl stop metis.service
  sudo systemctl status metis.service --no-pager
}

status_metis_service() {
  sudo systemctl status metis.service --no-pager
}

# Provision steps/execution
# =========================
install_mongodb
configure_mongodb
check_install_mongodb
setup_mongodb_auth
create_web_user
install_nodejs
setup_metis
configure_metis_env
save_credentials
create_metis_service
start_metis_service

echo -e "${green}[METIS] Installation and provisioning completed!${reset}"


#NOTES
# mongod will NOT start -- Q: Are you using a VM?
# Symptom: `mongod.service: Main process exited, code=dumped, status=4/ILL` <--- AVX flag and Windows "CPU protections" block passthrough of the VM to the CPU hardware...

#Consideration -- security/lockdown of code
# --Starting w/ disabled features: mongosh --nodb --eval "disableTelemetry()"
