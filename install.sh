#!/bin/bash
set -e
sleep 1
echo "🔥INSTALLING LPP: usr/local/bin YIPPEEE 🔥"
sleep 1
echo "lwk making a directory now"
sudo mkdir -p /usr/local/bin
sleep 1
echo "if we being fr we lwk js copying stuff lmao"

sudo cp bin/lpp /usr/local/bin/lpp
sudo cp bin/qbe /usr/local/bin/qbe
sleep 1
echo "setting perms now"
sudo chmod +x /usr/local/bin/lpp
sudo chmod +x /usr/local/bin/qbe
sleep 1
sleep 1
echo "------------------------------------------------"
echo "Installation complete 🔥🔥"
echo "lpp --help to verify fr" 
echo "------------------------------------------------"
