#!/usr/bin/env bash

proxies=0
delete=0
remove=0
new_installation=0
profile_name_par=""
profile_name=""


# -----------------------------------------------------------------------------------------------------------------------
# Parse command line options
# -----------------------------------------------------------------------------------------------------------------------

while getopts 'hrpdn:' opt; do
  case "$opt" in
   p)
      # import of profiles configs
      proxies=1
      ;;

    n)
      # name of dummy profile
      profile_name_par="$OPTARG"
      ;;

    d)
      # delete of ./proxies /* profiles
      delete=1
      ;;

    r)
      # remove installation
      remove=1
      ;;

    h)
      echo "Usage: $(basename $0) [-h] [-r] [-p] [-d] [-n profile_name]"
      exit 0
      ;;

    :)
      echo -e "option requires an argument.\nUsage: $(basename $0) [-h] [-r] [-p] [-d] [-n profile_name]"
      exit 1
      ;;

    ?)
      echo -e "Invalid command option.\nUsage: $(basename $0) [-h] [-r] [-p] [-d] [-n profile_name]"
      exit 1
      ;;
  esac
done


# -----------------------------------------------------------------------------------------------------------------------
# Function to delete all profiles created by this script, including the dummy one, and the ones imported from ./proxies
# -----------------------------------------------------------------------------------------------------------------------

delete_profiles() {
  sudo nmcli connection delete "$profile_name"

  cd proxies
  ls -1 | while read file
  do 
      conn_name=$(echo "$file" | sed -r "s/^(.*)\.conf/\1/")
      sudo nmcli connection delete "$conn_name"
  done
  cd ..
}

# --------------------------------------------------------------------
# Resolve config path deterministically and read it
# --------------------------------------------------------------------

ACTIVE_USER=$(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $3}' | head -n1)
USER_HOME=$(getent passwd "$ACTIVE_USER" 2>/dev/null | cut -d: -f6)

CONFIG="/etc/wg-vpn-auto.conf"
if [ !  -f "$CONFIG" ]
then
  if [ -n "$USER_HOME" ]; then
      CONFIG="$USER_HOME/.config/wg-vpn-auto.conf"
  else
      CONFIG=""
  fi
fi

if [ -f "$CONFIG" ]
then
  . "$CONFIG"
  echo "Using existing config: $CONFIG"
  profile_name="$DUMMY_CONN_ID"
fi

# --------------------------------------------------------------------
# Resolve dummy profile name and new installation status
# --------------------------------------------------------------------

if [ -z "$profile_name" ]
then
  if [ -n "$profile_name_par" ]
  then
    profile_name="$profile_name_par"
    new_installation=1
  else
    echo -e "This is the first installation on this machine, and not profile_name given.\nUsage: $(basename $0) [-p] [-d] [-n profile_name]"
    exit 1
  fi
else
  if [ -z "$profile_name_par" ]
  then
    profile_name_par="$profile_name"
  fi
fi


# --------------------------------------------------------------------
# Remove installation
# --------------------------------------------------------------------

if (( remove ))
then
  sudo nmcli connection down "$profile_name_par"
  sudo systemctl disable wg-vpn-auto
  sudo systemctl disable wg-vpn-auto-restore
  delete_profiles
  sudo rm -f /etc/wg-vpn-auto.conf
  sudo rm -f /usr/local/bin/wg-vpn-auto.py
  sudo rm -f /etc/systemd/system/wg-vpn-auto.service
  sudo rm -f /etc/systemd/system/wg-vpn-auto-restore.service
  sudo rm -f /etc/NetworkManager/dispatcher.d/90-wg-vpn-auto
  sudo rm -rf /var/lib/wg-vpn-auto
  sudo systemctl daemon-reload
  sudo systemctl restart NetworkManager
  echo "VPN auto ochestrator service installation removed."
  exit 0
fi


# --------------------------------------------------------------------
# Deleting connection profiles
# --------------------------------------------------------------------

if (( delete ))
then
  delete_profiles
fi


# --------------------------------------------------------------------
# Import of config files from subdirectory ./proxies
# --------------------------------------------------------------------

if (( proxies ))
then
  cd proxies
  ls -1 | while read file
  do 
      conn_name=$(echo "$file" | sed -r "s/^(.*)\.conf/\1/")
      sudo nmcli connection import type wireguard file $file
      sudo nmcli connection modify "$conn_name" connection.permissions "user:root" connection.autoconnect no
      sudo nmcli connection down "$conn_name"
      echo "$file file imported as $conn_name connection."
  done
  cd ..
fi


# ------------------------------------------------------------------------------
# Create and copy new config with dummy profile name to /etc/wg-vpn-auto.conf
# ------------------------------------------------------------------------------

cat wg-vpn-auto.conf > wg-vpn-auto.conf.tmp
echo >> wg-vpn-auto.conf.tmp
echo "# Installed dummy profile name" >> wg-vpn-auto.conf.tmp
echo "DUMMY_CONN_ID=\"$profile_name_par\"" >> wg-vpn-auto.conf.tmp
echo >> wg-vpn-auto.conf.tmp

sudo mv wg-vpn-auto.conf.tmp /etc/wg-vpn-auto.conf -f
rm -f wg-vpn-auto.conf.tmp
echo "/etc/wg-vpn-auto.conf created."


# ------------------------------------------------------------------------------------------------------------------
# Copy python daemon script, systemd service file and dispatcher script to their locations, and enable the service
# ------------------------------------------------------------------------------------------------------------------

sudo cp -f wg-vpn-auto.py /usr/local/bin/wg-vpn-auto.py
sudo chmod +x /usr/local/bin/wg-vpn-auto.py
echo "/usr/local/bin/wg-vpn-auto.py copied."

(( ! new_installation )) && sudo systemctl disable wg-vpn-auto
(( ! new_installation )) && sudo systemctl disable wg-vpn-auto-restore
sudo cp -f wg-vpn-auto.service /etc/systemd/system/wg-vpn-auto.service
echo "/etc/systemd/system/wg-vpn-auto.service copied."

sudo cp -f wg-vpn-auto-restore.service /etc/systemd/system/wg-vpn-auto-restore.service
echo "/etc/systemd/system/wg-vpn-auto-restore.service copied."

sudo cp -f dispatcher.sh /etc/NetworkManager/dispatcher.d/90-wg-vpn-auto
sudo chmod +x /etc/NetworkManager/dispatcher.d/90-wg-vpn-auto
echo "/etc/NetworkManager/dispatcher.d/90-wg-vpn-auto copied."

if (( delete || new_installation ))
then
  private_key=$(wg genkey)

  sudo nmcli connection add type wireguard con-name "$profile_name_par" ifname wg-auto
  sudo nmcli connection modify "$profile_name_par" wireguard.private-key "${private_key}" ipv4.method manual ipv4.addresses 10.255.255.1/32 ipv6.method ignore connection.autoconnect no connection.permissions ""

  sudo systemctl restart NetworkManager
  sudo nmcli connection down "$profile_name_par"
  echo "'$profile_name_par' dummy profile created."
fi

sudo mkdir -p /var/lib/wg-vpn-auto
sudo systemctl daemon-reload
sudo systemctl enable wg-vpn-auto-restore

if (( new_installation ))
then
  echo "Service created."
else
  echo "Service updated."
fi
