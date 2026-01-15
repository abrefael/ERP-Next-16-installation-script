#!/bin/bash


RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'


cat << EOF
This script was created to easily deploy Frappe-bench and\or ERP-Next 16 on a clean Debian 13+ or Ubuntu 24.04+ server.
You are required to have a frappe-dedicated user and the ability to SSH to your server with this user. In addition, the frappe-dedicated user, should have sudo permissions on the server. If you have the above we will guide you through the setup process.
The process is constructed of a few parts:

1. Setting the system time zone.
2. Installing some prerequisites.
3. configuring the beckend server (a mariaDB instance).
4. installing the base infrastructure (i.e.: Node, npm and yarn)
5. Installing Frappe-bench and initializing it.
6. (Optional) setting up a new site.
7. (Optional) Installing ERP-Next and additional custom applications.
8. (Optional) Making your server ready for production (currently without SSL conactivity).

This script is based on guides by Kibet_Sang:
https://discuss.frappe.io/t/frappe-erpnext-v16-installation-ubuntu-25/158457
and mathan21:
https://discuss.frappe.io/t/frappe-installation-steps-v16-production-ubuntu/159093

Good luck :-)

EOF
prompt_for_mariadb_password() {
    while true; do
        echo -ne "${YELLOW}Enter the desired password for MariaDB root user:${NC} "
        read -s mariadb_password
        echo
        echo -ne "${YELLOW}Confirm the MariaDB root password:${NC} "
        read -s mariadb_password_confirm
        echo
        if [ "$mariadb_password" = "$mariadb_password_confirm" ]; then
            break
        else
            echo -e "${RED}Passwords do not match. Please try again.${NC}"
        fi
    done
}


prompt_for_admin_password() {
    while true; do
        echo -ne "${YELLOW}Enter the desired Frappe administrator password:${NC} "
        read -s admin_password
        echo
        echo -ne "${YELLOW}Confirm the Frappe administrator password:${NC} "
        read -s admin_password_confirm
        echo
        if [ "$admin_password" = "$admin_password_confirm" ]; then
            break
        else
            echo -e "${RED}Passwords do not match. Please try again.${NC}"
        fi
    done
}

echo -e "Let's begin with your timezone.\nTake a look at your current date and time: $(date)\nIs it correct? [Y/n]"
read ans
if [ "$ans" = "n" ]; then
 echo -e "What is your time zone? (e.g.: Africa/Ceuta)\n (Hint: if you don't know your time zone identifier, checkout the following Wikipedia page:\nhttps://en.wikipedia.org/wiki/List_of_tz_database_time_zones)"
 read -p "" timez
 timedatectl set-timezone "$timez"
fi


ans=""
prompt_for_mariadb_password
prompt_for_admin_password
read -p "Please enter new site name: " newSite
sudo apt update && sudo apt upgrade -y
sudo apt install git libmariadb-dev-compat redis-server libmariadb-dev mariadb-server mariadb-client pkg-config xvfb libfontconfig cron curl build-essential gcc certbot python3-certbot-nginx ansible -y


MARKER_FILE=~/.MariaDB_handled.marker

if [ ! -f "$MARKER_FILE" ]; then
 echo "Let's configure your Mariadb server."
 prompt_for_mariadb_password
export mariadb_password
sudo mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$mariadb_password';"
sudo mysql -u root -p"$mariadb_password" -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$mariadb_password';"
sudo mysql -u root -p"$mariadb_password" -e "DELETE FROM mysql.user WHERE User='';"
sudo mysql -u root -p"$mariadb_password" -e "DROP DATABASE IF EXISTS test;DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';"
sudo mysql -u root -p"$mariadb_password" -e "FLUSH PRIVILEGES;"
sudo bash -c 'cat << EOF >> /etc/mysql/my.cnf
[mysqld]
character-set-client-handshake = FALSE
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci

[mysql]
default-character-set = utf8mb4
EOF'

sudo systemctl restart mariadb.service
 touch "$MARKER_FILE"
fi

sudo apt remove nodejs npm -y
sudo apt autoremove -y
sudo apt update
sudo apt upgrade -y
sudo apt install -y curl ca-certificates gnupg
sudo apt install -y libcairo2 libpango-1.0-0 libpangocairo-1.0-0 libgdk-pixbuf-2.0-0 libffi-dev shared-mime-info
curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash -
sudo apt install -y nodejs
sudo npm install -g yarn
curl -LsSf https://astral.sh/uv/install.sh | sh
source ~/.local/bin/env
uv python install 3.14 --default
source ~/.bashrc
.local/share/uv/tools/frappe-bench/bin/python -m ensurepip
uv tool install frappe-bench
source ~/.bashrc
bench init frappe-bench --frappe-branch version-16 --python python3.14
.local/share/uv/tools/frappe-bench/bin/python -m ensurepip
chmod -R o+rx .
cd frappe-bench/

export admin_password
bench new-site "$newSite" --admin-password "$admin_password" --set-default --db-root-username "root" --db-root-password "$mariadb_password"

echo -e "If you wish to install a custom apps, enter it's URIs.\nStarting with the first (Hit Enter for none):\n"
while read URI; do
 if [ "$URI" = "" ]; then
 break
 fi
 IFS='/' read -a array <<< "$URI"
 bench get-app --resolve-deps $URI
 app_name=${array[-1]}
 if [[ $app_name == *".git" ]]; then
 bench install-app "${app_name:0:-4}";
 else 
 bench install-app "${app_name}";
 fi
 URI=""
 echo -e "Any more apps? Enter another URI (otherwise hit Enter):\n"
done
read -p "Would you like to continue and install ERPNext? (y/N) " ans
if [ $ans = "y" ]; then 
  ans=""
  bench get-app payments
  bench get-app --branch version-16 erpnext
  bench get-app hrms
  bench install-app erpnext
  bench install-app hrms
fi
read -p "Good! Now, is your server ment for production? (Y/n) " ans
if [ $ans = "n" ]; then exit 0; fi 
ans=""
file="/home/$USER/.local/share/uv/tools/frappe-bench/lib/python3.14/site-packages/bench/playbooks/roles/nginx/tasks/vhosts.yml"
sed -i "s/  when: nginx_vhosts.*/  when: nginx_vhosts | length > 0/g" "$file"
file="/etc/nginx/nginx.conf"
sudo cp "$file" "$file.bak.$(date +%F_%H-%M-%S)"
if ! grep -q "log_format main" "$file"; then
    sudo awk '
    /##/ && c==0 {
        print; 
        getline; print; getline; print;
        print "\tlog_format main '\''$remote_addr - $remote_user [$time_local] '\'' '\''\"$request\" $status $body_bytes_sent '\'' '\''\"$http_referer\" \"$http_user_agent\"'\'';";
        c=1; next
    }1' "$file" | sudo tee "$file".tmp > /dev/null && sudo mv "$file".tmp "$file"
    echo "log_format main inserted into $file"
fi
loc=$(locale | grep LANG=)
if [[ $loc == *".UTF-8"* ]]; then
    echo "Locales are set correctly for production."
else
    IFS='=' read -a array <<< "$loc"
    loc=${array[-1]}
    if [[ $loc == *"."* ]]; then
        IFS='=' read -a array <<< "$loc"
        loc=${array[0]}
    sudo locale-gen $loc.UTF-8
    sudo localectl set-locale LANG=$loc.UTF-8
    echo "export LANG=$loc.UTF-8" >> ~/.bashrc
    source .bashrc
fi

export PATH=/usr/sbin:/usr/bin:$PATH
sudo env "PATH=/home/$USER/.local/bin:$PATH" bench setup production $USER
echo y | bench setup nginx
sudo service nginx reload
sudo supervisorctl reload
sudo env "PATH=/home/$USER/.local/bin:$PATH" bench setup production $USER

