#!/bin/bash
#These set of scripts are tested and only promised to be completely compatible with Ubuntu 16.04 LTS
#It should work on other unix system as long as you have dependencies installed

#Remember make this script able to execute! 
#sudo chmod +x upload-starter.sh

#This script should be ran at server boot. To do put in crontab 
#crontab -e
#@reboot screen -dmS GGbot sh -c "cd /real/path/to/scripts/upload-starter.sh; ./upload-starter.sh; exec sh"

##############################YOU NEED##################################################
##############################TO CHANGE#################################################
##############################ALL THESE#################################################
##############################VARIABLES BELOW###########################################

#Location of all shell scripts and items they use
#Don't include trailing slash (/) at end
HOME_FOLDER="/path/to/scripts"

#Your site API URL
#Don't include trailing slash (/) at end
API_URL="your-website.com/api/v1"

#Your site API key that is set in /var/www/config.php
API_KEY="your-api-key-here"

#Optional change
#Temporary location where RAR archives are stored
#Don't include trailing slash (/) at end
PATH_WORKING="/tmp/gog-compress"

##############################DID YOU####################################################
##############################CHANGE ALL#################################################
##############################THE VARIABLES##############################################
##############################FOUND ABOVE?###############################################

#Set colors
red=$(tput setaf 1)
green=$(tput setaf 2)
yellow=$(tput setaf 3)
blue=$(tput setaf 4)
reset=$(tput sgr0)

#Handles cURL error if can't connect and will retry
curl_retry_connect() {
    local RESPONSE_CODE
	set +e
    curl "$@"
    RESPONSE_CODE=$?

    # If exit code is 7 then retry
    if [ $RESPONSE_CODE -eq 7 ]; then
        echo "CURLE_COULDNT_CONNECT (7)"
        echo "Retrying..."
        curl_retry_connect "$@"
    fi
}

while true; do

#Check if temp directory exists, if not make it
if [ ! -d "$PATH_WORKING" ]; then
	mkdir $PATH_WORKING
fi

#Check if jq installed
if ! command -v jq >/dev/null 2>&1; then
    echo ${red}"jq is not installed. This is needed to parse json from API."${reset}
    echo ${red}"sudo apt install jq"${reset}
	sleep 15s
    continue
fi

#Check if rar installed
if ! command -v rar >/dev/null 2>&1; then
    echo ${red}"rar in not installed. This is need to archive files."${reset} 
	echo ${red}"sudo apt install rar"${reset} 
	sleep 15s
    continue
fi

#Check if python installed
if ! command -v python >/dev/null 2>&1; then
    echo ${red}"python in not installed. This is need to track upload time."${reset} 
	echo ${red}"sudo apt install python"${reset} 
	sleep 15s
    continue
fi

#Check if cURL installed
if ! command -v curl >/dev/null 2>&1; then
    echo ${red}"cURL in not installed. This is need to upload."${reset} 
	echo ${red}"sudo apt install curl"${reset} 
	sleep 15s
    continue
fi

#Pause queue
PAUSE_FILE="$HOME_FOLDER/PAUSE_QUEUE"
if [[ -f "$PAUSE_FILE" ]]; then
	echo ${red}Queue is paused.${reset} 
	sleep 15s
	continue
fi

#Clean gog-compress directory 
rm -rf $PATH_WORKING/*

#Get a game from queue API
QUEUE=$(curl_retry_connect -s $API_URL/queue -H "X-Api-Key: $API_KEY" --retry 15)
    
if [[ "$QUEUE" =~ "{" ]]; then
	GAME_FOLDER=$(echo $QUEUE | jq .id -r)
	GAME_NAME=$(echo $QUEUE | jq .title -r)
	GAME_SLUG_FOLDER=$(echo $QUEUE | jq .slug_folder -r )
	
	#Next game from queue API
	echo ${green}Up next: $GAME_NAME "|" $GAME_SLUG_FOLDER ${reset}
	
	./upload-script.sh $GAME_FOLDER 
	sleep 15
		else
	#Nothing in queue
	sleep 15
	echo ${red}Queue is empty. ${reset}
	continue
fi
done