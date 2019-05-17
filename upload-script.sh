#!/bin/bash
#These set of scripts are tested and only promised to be completely compatible with Ubuntu 16.04 LTS
#It should work on other unix system as long as you have dependencies installed

#Remember make this script able to execute! 
#sudo chmod +x upload-script.sh

##############################YOU NEED##################################################
##############################TO CHANGE#################################################
##############################ALL THESE#################################################
##############################VARIABLES BELOW###########################################

#Location of all shell scripts and items they use
#Don't include trailing slash (/) at end
HOME_FOLDER="/path/to/scripts"

#Your site API URL
#Don't include a trailing slash (/) at end
API_URL="your-website.com/api/v1"

#Your site API key that is set in /var/www/config.php
API_KEY="your-api-key-here"

#Root directory that has GOG games
#They must be in their own folder
#i.e. 
#army_men_ii/
#├── setup_army_men_ii_1.0_(gog-6)_(14770).exe
#└── army_men_2_manual.zip
#Do include trailing slash (/) at end
PATH_GAMES="/path/to/gog/games/"

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

IFS=$'\n'
GAME_ID=$1
GAME_INFO=$(curl_retry_connect -s "$API_URL/games/info?id=$GAME_ID" -H "X-Api-Key: $API_KEY" --retry 15)
GAME_INFO_SUCCESS=$(echo "$GAME_INFO" | jq '.SUCCESS' -r)
GAME_INFO_SLUG_FOLDER=$(echo "$GAME_INFO" | jq ".DATA.slug_folder" -r)
PATH_GAME="$PATH_GAMES$GAME_INFO_SLUG_FOLDER/" 
PATH_PATCH="${PATH_GAME}patch"
PATH_FINAL="$PATH_WORKING/$GAME_INFO_SLUG_FOLDER"

#Zippyshare upload functions
#Copy/paste from plowup zippyshare module to spend less time writing code
#Probably has error as calls functions that don't exist been stable so far...

parse() {
    local PARSE=$2
    local -i N=${3:-0}
    local -r D=$'\001' # Change sed separator to allow '/' characters in regexp
    local STR FILTER

    if [ -n "$1" -a "$1" != '.' ]; then
        FILTER="\\${D}$1${D}" # /$1/
    elif [ $N -ne 0 ]; then
        log_error "$FUNCNAME: wrong argument, offset argument is $N and filter regexp is \"$1\""
        return $ERR_FATAL
    fi

    [ '^' = "${PARSE:0:1}" ] || PARSE="^.*$PARSE"
    [ '$' = "${PARSE:(-1):1}" ] || PARSE+='.*$'
    PARSE="s${D}$PARSE${D}\1${D}p" # s/$PARSE/\1/p

    if [ $N -eq 0 ]; then
        # Note: This requires GNU sed (which is assumed by Plowshare)
        #STR=$(sed -ne "$FILTER {$PARSE;ta;b;:a;q;}")
        STR=$(sed -ne "$FILTER {$PARSE;T;q;}")

    elif [ $N -eq 1 ]; then
        #STR=$(sed -ne ":a $FILTER {n;h;$PARSE;tb;ba;:b;q;}")
        STR=$(sed -ne ":a $FILTER {n;$PARSE;Ta;q;}")

    elif [ $N -eq -1 ]; then
        #STR=$(sed -ne "$FILTER {g;$PARSE;ta;b;:a;q;}" -e 'h')
        STR=$(sed -ne "$FILTER {g;$PARSE;T;q;}" -e 'h')

    else
        local -r FIRST_LINE='^\([^\n]*\).*$'
        local -r LAST_LINE='^.*\n\(.*\)$'
        local N_ABS=$(( N < 0 ? -N : N ))
        local I=$(( N_ABS - 2 ))
        local LINES='.*'
        local INIT='N'
        local FILTER_LINE PARSE_LINE

        [ $N_ABS -gt 10 ] &&
            log_notice "$FUNCNAME: are you sure you want to skip $N lines?"

        while (( I-- )); do
            INIT+=';N'
        done

        while (( N_ABS-- )); do
            LINES+='\n.*'
        done

        if [ $N -gt 0 ]; then
            FILTER_LINE=$FIRST_LINE
            PARSE_LINE=$LAST_LINE
        else
            FILTER_LINE=$LAST_LINE
            PARSE_LINE=$FIRST_LINE
        fi

        # Note: Need to "clean" conditional flag after s/$PARSE_LINE/\1/
        STR=$(sed -ne "1 {$INIT;h;n}" \
            -e "H;g;s/^.*\\n\\($LINES\)$/\\1/;h" \
            -e "s/$FILTER_LINE/\1/" \
            -e "$FILTER {g;s/$PARSE_LINE/\1/;ta;:a;$PARSE;T;q;}")
    fi

    if [ -z "$STR" ]; then
        log_error "$FUNCNAME failed (sed): \"/$1/ ${PARSE//$D//}\" (skip $N)"
        log_notice_stack
        return $ERR_FATAL
    fi

    echo "$STR"
}

grep_form_by_id() {
    local -r A=${2:-'.*'}
    local STR=$(sed -ne \
        "/<[Ff][Oo][Rr][Mm][[:space:]].*id[[:space:]]*=[[:space:]]*[\"']\?$A[\"']\?[[:space:]/>]/,/<\/[Ff][Oo][Rr][Mm]>/p" <<< "$1")

    if [ -z "$STR" ]; then
        log_error "$FUNCNAME failed (sed): \"id=$A\""
        return $ERR_FATAL
    fi

    echo "$STR"
}

parse_attr() {
    local -r A=${2:-"$1"}
    local -r D=$'\001'
    local STR=$(sed \
        -ne "\\${D}$1${D}s${D}.*[[:space:]]\($A\)[[:space:]]*=[[:space:]]*\"\([^\">]*\).*${D}\2${D}p;ta" \
        -ne "\\${D}$1${D}s${D}.*[[:space:]]\($A\)[[:space:]]*=[[:space:]]*'\([^'>]*\).*${D}\2${D}p;ta" \
        -ne "\\${D}$1${D}s${D}.*[[:space:]]\($A\)[[:space:]]*=[[:space:]]*\([^[:space:]\"\`'<=>]\+\).*${D}\2${D}p;ta" \
        -ne 'b;:a;q;')

    if [ -z "$STR" ]; then
        log_error "$FUNCNAME failed (sed): \"/$1/ $A=\""
        log_notice_stack
        return $ERR_FATAL
    fi

    echo "$STR"
}

parse_form_action() {
    parse_attr '<[Ff][Oo][Rr][Mm]' 'action'
}

parse_form_input_by_name() {
    parse_attr "<[Ii][Nn][Pp][Uu][Tt][^>]*name[[:space:]]*=[[:space:]]*[\"']\?$1[\"']\?[[:space:]/>]" 'value'
}

zippyshare_upload_game() {
local -r BASE_URL='http://www.zippyshare.com'
local PAGE SERVER FORM_HTML FORM_ACTION FORM_UID FILE_URL FORM_DATA_AUTH

PAGE=$(curl -s -L -b 'ziplocale=en' "$BASE_URL") || return
SERVER=$(echo "$PAGE" | parse 'var[[:space:]]*server' "'\([^']*\)';")
FORM_HTML=$(grep_form_by_id "$PAGE" 'upload_form') || return
FORM_ACTION=$(echo "$FORM_HTML" | parse_form_action) || return
FORM_UID=$(echo "$FORM_HTML" | parse_form_input_by_name 'uploadId') || return

    # Important: field order seems checked! zipname/ziphash go before Filedata!
    PAGE=$(curl -F "uploadId=$FORM_UID" \
        $FORM_DATA_AUTH \
        -F "Filedata=@$PATH_WORKING/$GAME_INFO_SLUG_FOLDER/$fname" --progress-bar --connect-timeout 2 --speed-time 5 --retry 8 \
        "$FORM_ACTION") || return

    # Take first occurrence
    FILE_URL=$(echo "$PAGE" | parse '="file_upload_remote"' '^\(.*\)$' 1) || return

    echo "$FILE_URL"
}

zippyshare_upload_goodies() {
local -r BASE_URL='http://www.zippyshare.com'
local PAGE SERVER FORM_HTML FORM_ACTION FORM_UID FILE_URL FORM_DATA_AUTH

PAGE=$(curl -s -L -b 'ziplocale=en' "$BASE_URL") || return
SERVER=$(echo "$PAGE" | parse 'var[[:space:]]*server' "'\([^']*\)';")
FORM_HTML=$(grep_form_by_id "$PAGE" 'upload_form') || return
FORM_ACTION=$(echo "$FORM_HTML" | parse_form_action) || return
FORM_UID=$(echo "$FORM_HTML" | parse_form_input_by_name 'uploadId') || return

    # Important: field order seems checked! zipname/ziphash go before Filedata!
    PAGE=$(curl -F "uploadId=$FORM_UID" \
        $FORM_DATA_AUTH \
        -F "Filedata=@$PATH_WORKING/$GAME_INFO_SLUG_FOLDER/goodies/$fname" --progress-bar --connect-timeout 2 --speed-time 5 --retry 8 \
        "$FORM_ACTION") || return

    # Take first occurrence
    FILE_URL=$(echo "$PAGE" | parse '="file_upload_remote"' '^\(.*\)$' 1) || return

    echo "$FILE_URL"
}

zippyshare_upload_patch() {
local -r BASE_URL='http://www.zippyshare.com'
local PAGE SERVER FORM_HTML FORM_ACTION FORM_UID FILE_URL FORM_DATA_AUTH

PAGE=$(curl -s -L -b 'ziplocale=en' "$BASE_URL") || return
SERVER=$(echo "$PAGE" | parse 'var[[:space:]]*server' "'\([^']*\)';")
FORM_HTML=$(grep_form_by_id "$PAGE" 'upload_form') || return
FORM_ACTION=$(echo "$FORM_HTML" | parse_form_action) || return
FORM_UID=$(echo "$FORM_HTML" | parse_form_input_by_name 'uploadId') || return

    # Important: field order seems checked! zipname/ziphash go before Filedata!
    PAGE=$(curl -F "uploadId=$FORM_UID" \
        $FORM_DATA_AUTH \
        -F "Filedata=@$PATH_WORKING/$GAME_INFO_SLUG_FOLDER/patch/$fname" --progress-bar --connect-timeout 2 --speed-time 5 --retry 8 \
        "$FORM_ACTION") || return

    # Take first occurrence
    FILE_URL=$(echo "$PAGE" | parse '="file_upload_remote"' '^\(.*\)$' 1) || return

    echo "$FILE_URL"
}

while true; do

#Don't continue if game ID was not supplied
if [ -z "$GAME_ID" ]; then
    echo ${red}"Game ID was not supplied!"${reset} 
    continue
fi

#Don't continue if game directory doesn't exist
if [ ! -d "$PATH_GAME" ]; then
    echo ${red}"GAME FOLDER DOES NOT EXIST! "$GAME_INFO_SLUG_FOLDER""${reset}
    continue
fi

#Don't continue if no exe file in game folder
GAME_EXE_FILE_CHECK=$(find $PATH_GAME -name "*.exe" | wc -l)
if [[ $GAME_EXE_FILE_CHECK -eq "0" ]]; then
    echo ${red}"NO FILES IN FOLDER! "$GAME_INFO_SLUG_FOLDER""${reset}
    continue
fi

#Check if error
if [[ $GAME_INFO_SUCCESS = "false" ]]; then
    echo $(echo "$GAME_INFO" | jq '.MSG')
    continue
fi
break
done

#Compress function
compress() {
    local OUTPUT INPUT
    OUTPUT=$1
    INPUT=$2
    if [[ $(uname -s) =~ ^CYGWIN* ]]; then
        INPUT="$(cygpath -u $INPUT)"
    fi
    rar a -ep1 -m0 -v524288000b "$OUTPUT.rar" $INPUT
}

#Size in bytes
get_filesize() {
    local FILE_SIZE=$(ls -l "$1" 2>/dev/null | sed -e 's/[[:space:]]\+/ /g' | cut -d' ' -f5)
    echo "$FILE_SIZE"
}

#Make GAME compress directory
mkdir -p $PATH_FINAL

#Set patches variable
HAS_PATCH=false
if [ -d "$PATH_PATCH" ]; then
    HAS_PATCH=true
    LIST_PATCH='find $PATH_PATCH -maxdepth 1 -type f'
fi

#Look for goodies
#You can list .exe goodies you want under goodies included, do after: -or -iname "setup_kingdom_2.6.0.7.exe"
LIST_GOODIES='find $PATH_GAME -maxdepth 1 -type f \( -iname "*" ! -iname "*.exe" ! -iname "*.bin" -or -iname "setup_kingdom_2.6.0.7.exe" -or -iname "setup_bioshock_1.1_(25450).exe" -or -iname "setup_bioshock_1.1_(25450)-1.bin" -or -iname "setup_bioshock_2_1.5.0.019_(25143).exe" -or -iname "setup_bioshock_2_1.5.0.019_(25143)-1.bin" -or -iname "setup_bioshock_2_1.5.0.019_(25143)-2.bin" -or -iname "setup_bioshock_2_1.5.0.019_(25143)-3.bin" -or -iname "setup_syberia2_russian_2.1.0.1.exe" -or -iname "setup_skaut_kwatermaster_polish_2.0.0.3.exe.zip" -or -iname "setup_soltys_polish_2.0.0.5.exe.zip" -or -iname "setup_shadowrun_dragonfall_directors_cut_zog_russian_2.1.1.8.exe" -or -iname "setup_sacrifice_russian_2.1.0.4.exe" -or -iname "setup_planescape_torment_russian_2.1.0.9.exe" -or -iname "setup_mdk2_russian_2.1.0.3.exe" -or -iname "setup_little_inferno_russian_2.0.0.2.exe" -or -iname "setup_kingpin_russian_2.1.0.7.exe" -or -iname "setup_planescape_torment_1.01_(10597).exe" -or -iname "setup_postal2_complete_2.0.0.6.exe" -or -iname "setup_crimsonland_classic_2.0.0.4.exe" -or -iname "setup_seven_kingdoms2_2.0.0.7.exe" -or -iname "setup_outcast_2.0.0.13.exe" -or -iname "setup_yooka_laylee_toybox_2.0.0.2.exe" -or -iname "setup_stronghold_crusader_2.0.0.2.exe" -or -iname "setup_strike_suit_zero_2.1.0.12.exe" -or -iname "setup_octodad_2.0.0.1.exe" -or -iname "setup_jazz_jackrabbit_2_1.24_jj2_(16885).exe" -or -iname "setup_rocket_ranger_german_2.0.0.1.exe" -or -iname "setup_curse_of_the_azure_bonds_v12_2.0.0.1.exe" -or -iname "setup_lone_survivor_2.0.0.2.exe" -or -iname "setup_sublevelzero_1.2_(9875).exe" -or -iname "setup_rune_gold_2.0.0.5.exe" -or -iname "setup_dark_fall_lights_out.exe" -or -iname "setup_prisoner_of_ice_uk_2.0.0.1.exe" -or -iname "setup_falcon_4_2.0.0.1.exe" -or -iname "setup_ether_one_2.1.0.7.exe" -or -iname "setup_spelunky_classic_2.0.0.5.exe" -or -iname "setup_broken_sword1_2.0.0.8.exe" -or -iname "setup_stronghold_2.0.0.9.exe" -or -iname "setup_shadow_of_the_comet_floppy_2.0.0.3.exe" -or -iname "setup_oddworld_strangers_wrath_2.0.0.11.exe" -or -iname "setup_earth_2140_dos_2.0.0.16.exe" -or -iname "setup_homm2_gold_win_2.0.0.7.exe" -or -iname "setup_mind_path_to_thalamus_bonus_2.0.0.3.exe" -or -iname "setup_broken_sword2_2.0.0.6.exe" -or -iname "setup_defenders_quest_2.11.0.18.exe" -or -iname "setup_annas_quest_bonus_2.0.0.1.exe" -or -iname "setup_another_world_2.0.0.4.exe" -or -iname "setup_wizardry7dos_2.0.0.11.exe" -or -iname "setup_wizardry7dos_german_2.2.0.2.exe" -or -iname "setup_the_entertainment_2.0.0.1.exe" -or -iname "setup_limits_and_demontrations_2.0.0.1.exe" -or -iname "setup_kentucky_route_zero_interlude_2.0.0.2.exe" -or -iname "setup_to_the_moon_holiday_minisode1_2.1.0.2.exe" -or -iname "setup_to_the_moon_holiday_minisode1_german_2.1.0.2.exe" -or -iname "setup_to_the_moon_holiday_minisode1_ukrainian_2.1.0.2.exe" -or -iname "setup_to_the_moon_holiday_minisode2_2.1.0.2.exe" -or -iname "setup_to_the_moon_holiday_minisode2_german_2.1.0.2.exe" -or -iname "setup_to_the_moon_holiday_minisode2_ukrainian_2.1.0.2.exe" -or -iname "setup_to_the_moon_holiday_special_minisode_2.0.0.1.exe" \)'
#Set goodies variable
HAS_EXTRA=false
if ! [ -z "$(eval $LIST_GOODIES)" ]; then
    HAS_EXTRA=true
fi

echo "Doing pre-upload tasks..."
sleep 3s
curl_retry_connect -s -X POST -H 'Content-Type: application/json' -H "X-Api-Key: $API_KEY" -d "{\"id\":$GAME_ID}" "$API_URL/games/preupload" --retry 15 -o /dev/null

#Look for game files
#You can list setup.exe goodies you don't want under the game files included after: ! -iname "setup_kingdom_2.6.0.7.exe" 
#If want to add bin files, add at the very end -not -name "name_of_file.bin"
LIST_GAME='find $PATH_GAME -maxdepth 1 -type f \( -iname "*.exe*" ! -iname "setup_postal2_complete_2.0.0.6.exe" ! -iname "setup_kingdom_2.6.0.7.exe" ! -iname "setup_bioshock_1.1_(25450).exe" ! -iname "setup_bioshock_2_1.5.0.019_(25143).exe" ! -iname "setup_syberia2_russian_2.1.0.1.exe" ! -iname "setup_skaut_kwatermaster_polish_2.0.0.3.exe.zip" ! -iname "setup_soltys_polish_2.0.0.5.exe.zip" ! -iname "setup_shadowrun_dragonfall_directors_cut_zog_russian_2.1.1.8.exe" ! -iname "setup_sacrifice_russian_2.1.0.4.exe" ! -iname "setup_planescape_torment_russian_2.1.0.9.exe" ! -iname "setup_mdk2_russian_2.1.0.3.exe" ! -iname "setup_little_inferno_russian_2.0.0.2.exe" ! -iname "setup_kingpin_russian_2.1.0.7.exe" ! -iname "setup_planescape_torment_1.01_(10597).exe" ! -iname "setup_crimsonland_classic_2.0.0.4.exe" ! -iname "setup_seven_kingdoms2_2.0.0.7.exe" ! -iname "setup_outcast_2.0.0.13.exe" ! -iname "setup_yooka_laylee_toybox_2.0.0.2.exe" ! -iname "setup_stronghold_crusader_2.0.0.2.exe" ! -iname "setup_strike_suit_zero_2.1.0.12.exe" ! -iname "setup_octodad_2.0.0.1.exe" ! -iname "setup_jazz_jackrabbit_2_1.24_jj2_(16885).exe" ! -iname "setup_rocket_ranger_german_2.0.0.1.exe" ! -iname "setup_curse_of_the_azure_bonds_v12_2.0.0.1.exe" ! -iname "setup_lone_survivor_2.0.0.2.exe" ! -iname "setup_sublevelzero_1.2_(9875).exe" ! -iname "setup_rune_gold_2.0.0.5.exe" ! -iname "setup_dark_fall_lights_out.exe" ! -iname "setup_prisoner_of_ice_uk_2.0.0.1.exe" ! -iname "setup_falcon_4_2.0.0.1.exe" ! -iname "setup_ether_one_2.1.0.7.exe" ! -iname "setup_spelunky_classic_2.0.0.5.exe" ! -iname "setup_broken_sword1_2.0.0.8.exe" ! -iname "setup_stronghold_2.0.0.9.exe" ! -iname "setup_shadow_of_the_comet_floppy_2.0.0.3.exe" ! -iname "setup_oddworld_strangers_wrath_2.0.0.11.exe" ! -iname "setup_earth_2140_dos_2.0.0.16.exe" ! -iname "setup_homm2_gold_win_2.0.0.7.exe" ! -iname "setup_mind_path_to_thalamus_bonus_2.0.0.3.exe" ! -iname "setup_broken_sword2_2.0.0.6.exe" ! -iname "setup_defenders_quest_2.11.0.18.exe" ! -iname "setup_annas_quest_bonus_2.0.0.1.exe" ! -iname "setup_another_world_2.0.0.4.exe" ! -iname "setup_wizardry7dos_2.0.0.11.exe" ! -iname "setup_wizardry7dos_german_2.2.0.2.exe" ! -iname "setup_the_entertainment_2.0.0.1.exe" ! -iname "setup_limits_and_demontrations_2.0.0.1.exe" ! -iname "setup_kentucky_route_zero_interlude_2.0.0.2.exe" ! -iname "setup_to_the_moon_holiday_minisode1_2.1.0.2.exe" ! -iname "setup_to_the_moon_holiday_minisode1_german_2.1.0.2.exe" ! -iname "setup_to_the_moon_holiday_minisode1_ukrainian_2.1.0.2.exe" ! -iname "setup_to_the_moon_holiday_minisode2_2.1.0.2.exe" ! -iname "setup_to_the_moon_holiday_minisode2_german_2.1.0.2.exe" ! -iname "setup_to_the_moon_holiday_minisode2_ukrainian_2.1.0.2.exe" ! -iname "setup_to_the_moon_holiday_special_minisode_2.0.0.1.exe" -or -iname "*.url" -or -iname "*.txt" -or -iname "*.bin" -not -name "setup_bioshock_2_1.5.0.019_(25143)-1.bin" -not -name "setup_bioshock_2_1.5.0.019_(25143)-2.bin" -not -name "setup_bioshock_2_1.5.0.019_(25143)-3.bin" -not -name "setup_bioshock_1.1_(25450)-1.bin" \)'

echo "Clearing files..."
sleep 3s
curl_retry_connect -s -X POST -H 'Content-Type: application/json' -H "X-Api-Key: $API_KEY" -d "{\"id\":$GAME_ID}" "$API_URL/games/clearfiles" --retry 15 -o /dev/null

echo "Building list of files..."
sleep 3s

LIST_FINAL="{\"GAME\": [],\"GOODIES\": [],\"PATCHES\": []}"

#Build list of game files
LIST_FINAL_GAME_TEMP=$(echo $(eval $LIST_GAME -printf "%pnewline") | jq --raw-output --raw-input --slurp 'split("newline") | map(select(. != "\n")) | .[]')
LIST_FINAL_GAME="[]"

#Add filenames
for file in $LIST_FINAL_GAME_TEMP; do
    docont=false
    for extrafile in $(echo $LIST_EXTRA_FILES | tr "|" "\n"); do
        if [[ $file = *$(basename $extrafile)* ]]; then
            docont=true
        fi
    done
    if $docont; then
        continue
    fi
    LIST_FINAL_GAME=$(echo $LIST_FINAL_GAME | jq ". += [{\"name\": \"$(basename $file)\",\"size\": $(wc -c < "$file")}]")
done

#Add game list to final list
LIST_FINAL=$(echo $LIST_FINAL | jq ".GAME += $LIST_FINAL_GAME")

if $HAS_PATCH; then
    #Build list of patch files
    LIST_FINAL_PATCH_TEMP=$(echo $(eval $LIST_PATCH -printf "%pnewline") | jq --raw-output --raw-input --slurp 'split("newline") | map(select(. != "\n")) | .[]')

    LIST_FINAL_PATCH="[]"
    #Add filenames
    for file in $LIST_FINAL_PATCH_TEMP; do
        docont=false
        for extrafile in $(echo $LIST_EXTRA_FILES | tr "|" "\n"); do
            if [[ $file = *$(basename $extrafile)* ]]; then
                docont=true
            fi
        done
        if $docont; then
            continue
        fi
        LIST_FINAL_PATCH=$(echo $LIST_FINAL_PATCH | jq ". += [{\"name\": \"$(basename $file)\",\"size\": $(wc -c < "$file")}]")
    done
    #Add patch list to final list
    LIST_FINAL=$(echo $LIST_FINAL | jq ".PATCHES += $LIST_FINAL_PATCH")
fi

if $HAS_EXTRA; then
    #Build list of goodies files
    LIST_FINAL_GOODIES_TEMP=$(echo $(eval $LIST_GOODIES -printf "%pnewline") | jq --raw-output --raw-input --slurp 'split("newline") | map(select(. != "\n")) | .[]')
    
	LIST_FINAL_GOODIES="[]"
    #Add filenames
    for file in $LIST_FINAL_GOODIES_TEMP; do
        docont=false
        for extrafile in $(echo $LIST_EXTRA_FILES | tr "|" "\n"); do
            if [[ $file = *$(basename $extrafile)* ]]; then
                docont=true
            fi
        done
        if $docont; then
            continue
        fi
        LIST_FINAL_GOODIES=$(echo $LIST_FINAL_GOODIES | jq ". += [{\"name\": \"$(basename $file)\",\"size\": $(wc -c < "$file")}]")
    done
    #Add goodies list to final list
    LIST_FINAL=$(echo $LIST_FINAL | jq ".GOODIES += $LIST_FINAL_GOODIES" -r)
fi

echo "Sending new files to API..."
sleep 3s
curl_retry_connect -s -X POST -H 'Content-Type: application/json' -H "X-Api-Key: $API_KEY" -d "{\"id\":$GAME_ID,\"FILES\":$LIST_FINAL}" "$API_URL/games/addfiles" --retry 15 -o /dev/null

#Compress and upload PATCH
if $HAS_PATCH; then
    echo "--------------------------------------------------------------------------------------------------------------------------------------------------"
    echo "Compressing: PATCH"
    mkdir -p "$PATH_FINAL/patch/"
    compress "$PATH_FINAL/patch/patch-fix-other-${GAME_INFO_SLUG_FOLDER}" "$(eval $LIST_PATCH)"
    LIST_PATCH_COMPRESSED='find "$PATH_FINAL/$GAME_INFO_SLUG_FOLDER/patch/" -maxdepth 1 -type f'
fi

if $HAS_PATCH; then
	echo "--------------------------------------------------------------------------------------------------------------------------------------------------"
	echo "Upload started for: PATCH"
	START_UPLOAD_TIME_PATCH=$(date +%s)
	echo Total archives: $(find $PATH_WORKING/$GAME_INFO_SLUG_FOLDER/patch/ -maxdepth 1 -type f -name "*rar*" | wc -l)
	echo Size: $(du -h $PATH_WORKING/$GAME_INFO_SLUG_FOLDER/patch/ | cut -f1)
	echo
	find "$PATH_WORKING/$GAME_INFO_SLUG_FOLDER/patch/" -maxdepth 1 -type f -name "*rar*" | grep -o '[^/]*$' | sort -V | while read fname; do
	for (( ; ; ))
	do
	echo ${yellow}In-progress: $fname ${reset}
	LINK_ZIPPYSHARE_PATCH=$(zippyshare_upload_patch)
	echo $LINK_ZIPPYSHARE_PATCH
	if [[ $LINK_ZIPPYSHARE_PATCH =~ "https" ]]; then
		break
	fi
	done
	curl_retry_connect -s -X POST -H 'Content-Type: application/json' -H "X-Api-Key: $API_KEY" -d "{\"id\":$GAME_ID,\"type\":\"PATCHES\",\"host\":\"zippyshare\",\"filename\":\"$fname\",\"link\":\"$LINK_ZIPPYSHARE_PATCH\"}" "$API_URL/games/addlink" --retry 15 -o /dev/null
	echo  ${green}Completed: $fname ${reset}
	echo
	done
	END_UPLOAD_TIME_PATCH=$(date +%s)
	RUNTIME_UPLOAD_PATCH=$(python -c "print '%u:%02u' % ((${END_UPLOAD_TIME_PATCH} - ${START_UPLOAD_TIME_PATCH})/60, (${END_UPLOAD_TIME_PATCH} - ${START_UPLOAD_TIME_PATCH})%60)")
	echo ${green}"PATCH upload was completed in $RUNTIME_UPLOAD_PATCH" ${reset}
fi

sleep 3s

#Compress and upload GAME
echo "--------------------------------------------------------------------------------------------------------------------------------------------------"
echo "Compressing: GAME"
compress "$PATH_FINAL/game-$GAME_INFO_SLUG_FOLDER" "$(eval $LIST_GAME)"
LIST_GAME_COMPRESSED='find $PATH_FINAL -maxdepth 1 -type f'

echo "--------------------------------------------------------------------------------------------------------------------------------------------------"
echo "Upload started for: GAME"
START_UPLOAD_TIME_GAME=$(date +%s)
echo Total archives: $(find $PATH_WORKING/$GAME_INFO_SLUG_FOLDER/ -maxdepth 1 -type f -name "*rar*" | wc -l)
echo Size: $(du -sh --total $PATH_WORKING/$GAME_INFO_SLUG_FOLDER/*.rar | cut -f1 | tail -n1)
echo
find "$PATH_WORKING/$GAME_INFO_SLUG_FOLDER/" -maxdepth 1 -type f -name "*rar*" | grep -o '[^/]*$' | sort -V | while read fname; do
for (( ; ; ))
do
echo ${yellow}In-progress: $fname ${reset}
LINK_ZIPPYSHARE_GAME=$(zippyshare_upload_game)
echo $LINK_ZIPPYSHARE_GAME
if [[ $LINK_ZIPPYSHARE_GAME =~ "https" ]]; then
	break
fi
done
curl_retry_connect -s -X POST -H 'Content-Type: application/json' -H "X-Api-Key: $API_KEY" -d "{\"id\":$GAME_ID,\"type\":\"GAME\",\"host\":\"zippyshare\",\"filename\":\"$fname\",\"link\":\"$LINK_ZIPPYSHARE_GAME\"}" "$API_URL/games/addlink" --retry 15 -o /dev/null
echo  ${green}Completed: $fname ${reset}
echo
done
END_UPLOAD_TIME_GAME=$(date +%s)
RUNTIME_UPLOAD_GAME=$(python -c "print '%u:%02u' % ((${END_UPLOAD_TIME_GAME} - ${START_UPLOAD_TIME_GAME})/60, (${END_UPLOAD_TIME_GAME} - ${START_UPLOAD_TIME_GAME})%60)")
echo ${green}"GAME upload was completed in $RUNTIME_UPLOAD_GAME"${reset}

sleep 3s 

#Compress and upload EXTRAS
if $HAS_EXTRA; then
    echo "--------------------------------------------------------------------------------------------------------------------------------------------------"
    echo "Compressing: GOODIES"
    mkdir -p "$PATH_FINAL/goodies/"
    compress "$PATH_FINAL/goodies/extras-${GAME_INFO_SLUG_FOLDER}" "$(eval $LIST_GOODIES)"
    LIST_GOODIES_COMPRESSED='find "$PATH_FINAL/goodies/" -maxdepth 1 -type f'
fi

if $HAS_EXTRA; then
	echo "--------------------------------------------------------------------------------------------------------------------------------------------------"
	echo "Upload started for: GOODIES"
	START_UPLOAD_TIME_GOODIES=$(date +%s)
	echo Total archives: $(find $PATH_WORKING/$GAME_INFO_SLUG_FOLDER/goodies/ -maxdepth 1 -type f -name "*rar*" | wc -l)
	echo Size: $(du -h $PATH_WORKING/$GAME_INFO_SLUG_FOLDER/goodies/ | cut -f1)
	echo
	find "$PATH_WORKING/$GAME_INFO_SLUG_FOLDER/goodies/" -maxdepth 1 -type f -name "*rar*" | grep -o '[^/]*$' | sort -V | while read fname; do
	for (( ; ; ))
	do
	echo ${yellow}In-progress: $fname ${reset}
	LINK_ZIPPYSHARE_EXTRA=$(zippyshare_upload_goodies)
	echo $LINK_ZIPPYSHARE_EXTRA
	if [[ $LINK_ZIPPYSHARE_EXTRA =~ "https" ]]; then
		break
	fi
	done
	curl_retry_connect -s -X POST -H 'Content-Type: application/json' -H "X-Api-Key: $API_KEY" -d "{\"id\":$GAME_ID,\"type\":\"GOODIES\",\"host\":\"zippyshare\",\"filename\":\"$fname\",\"link\":\"$LINK_ZIPPYSHARE_EXTRA\"}" "$API_URL/games/addlink" --retry 15 -o /dev/null
	echo  ${green}Completed: $fname ${reset}
	echo
	done
	END_UPLOAD_TIME_GOODIES=$(date +%s)
	RUNTIME_UPLOAD_GOODIES=$(python -c "print '%u:%02u' % ((${END_UPLOAD_TIME_GOODIES} - ${START_UPLOAD_TIME_GOODIES})/60, (${END_UPLOAD_TIME_GOODIES} - ${START_UPLOAD_TIME_GOODIES})%60)")
	echo ${green}"GOODIES upload was completed in $RUNTIME_UPLOAD_GOODIES"${reset}
fi

echo "--------------------------------------------------------------------------------------------------------------------------------------------------"
echo "Doing post-upload tasks..."
sleep 3s

curl_retry_connect -s -X POST -H 'Content-Type: application/json' -H "X-Api-Key: $API_KEY" -d "{\"id\":$GAME_ID}" "$API_URL/games/postupload" --retry 15 -o /dev/null
echo "Upload completed. Now resting..."
sleep 3s
echo "Cleaning up extra files..."
rm -rf $PATH_WORKING/*
sleep 3s
#Remove patch folder
for file in $(echo $LIST_EXTRA_FILES | tr "|" "\n"); do
    if [ -f $file ]; then
        echo "Delete: $(basename $file)"
        rm "$PATH_GAME$(basename $file)"
        if $HAS_PATCH; then
            if [[ $(uname -s) =~ ^CYGWIN* ]]; then
                rm "$(cygpath -u "$PATH_GAME/patch/$(basename $file)")"
            else
                rm "$PATH_GAME/patch/$(basename $file)"
            fi
        fi
    fi
done
echo "Removing un-wanted patch files..."
sleep 3s
if $HAS_PATCH; then
    rm -rf "$PATH_PATCH"
fi