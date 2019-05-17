#!/bin/bash
#THIS SCRIPT REQUIRES SCREEN!
#sudo apt install screen

#These set of scripts are tested and only promised to be completely compatible with Ubuntu 16.04 LTS
#It should work on other unix system as long as you have dependencies installed

#Remember make this script able to execute! 
#sudo chmod +x keepalive.sh

#Set this script in crontab to run every minute or desired time interval
#crontab -e
#* * * * * /real/path/to/scripts/keepalive.sh

##############################YOU NEED##################################################
##############################TO CHANGE#################################################
##############################ALL THESE#################################################
##############################VARIABLES BELOW!##########################################

#Location of all shell scripts and items they use
#Don't include trailing slash (/) at end
HOME_FOLDER="/home/goggames/scripts"

##############################DID YOU####################################################
##############################CHANGE ALL#################################################
##############################THE VARIABLES##############################################
##############################FOUND ABOVE?###############################################

#Exit if screen not installed
if ! command -v screen >/dev/null 2>&1; then
    exit
fi

#Check if upload-starter script alive
CHECK_SCRIPT_ALIVE=$(pgrep -n upload-starter)

#Location of blank PAUSE file			  
PAUSE_FILE="$HOME_FOLDER/PAUSE"

#Debug PID
#echo $CHECK_SCRIPT_ALIVE >> $HOME_FOLDER/alive.txt

#If PAUSE file is found then don't do anything and exit
if [[ -f "$PAUSE_FILE" ]]; then
	exit
fi

#Check if upload script is running, if not start it in a GGbot screen
if [[ ! "$CHECK_SCRIPT_ALIVE" ]]; then
	screen -X -S GGbot quit
	sleep 5s
	screen -dmS GGbot sh -c "cd $HOME_FOLDER/; ./upload-starter.sh; exec sh"
fi