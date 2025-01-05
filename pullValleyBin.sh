wget https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz -qO steamcmd.tar.gz
tar -xzvf steamcmd.tar.gz -C ./steamcmd
apt-get install lib32gcc-s1 -y
cd ./steamcmd
./steamcmd.sh +quit
./steamcmd.sh +force_install_dir ../valleybin +login ${STEAM_USER} ${STEAM_PASS} +app_update 413150 validate +quit