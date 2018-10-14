#!/bin/bash
#
# <bitbar.title>PPTP Client</bitbar.title>
# <bitbar.version>v1.0</bitbar.version>
# <bitbar.author>Jiri Hybek</bitbar.author>
# <bitbar.author.github>jirihybek</bitbar.author.github>
# <bitbar.desc>Allows to control PPTP connections via PPPD.</bitbar.desc>

# Config
RUN_DIR=~/.bitbar_pptp/run
LOG_DIR=~/.bitbar_pptp/log
#PEER_DIR=/etc/ppp/peers
PEER_DIR=~/.bitbar_pptp/peers
TEXT_EDITOR=/Applications/TextEdit.app/Contents/MacOS/TextEdit

# Ensure all dirs exist and has proper rights
mkdir -p $RUN_DIR
mkdir -p $LOG_DIR
mkdir -p $PEER_DIR
#chmod u+s /usr/sbin/pppd

# Read values
CURR_PWD=`pwd`
SELF_PATH="$0"
PEER_FILES=($PEER_DIR/*)
PEER_LIST=()
PEER_PIDS=()
PEER_TIME=()
PEER_CONN_COUNT=0

TIME_NOW=`date +%s`

###
# Load peer list with its pids
###
function load_list()
{

    # Get peer list with pids
    for PEER_FILE in "${PEER_FILES[@]}"
    do
        PEER_NAME=`basename "$PEER_FILE"`

        if [ "$PEER_NAME" == "*" ]; then
            continue
        fi

        PID_FILE="$RUN_DIR/$PEER_NAME"

        PEER_LIST+=( "$PEER_NAME" )

        RUN_FILE=`cat "$PID_FILE" 2> /dev/null`
        RUN_RET=$?

        if [ $RUN_RET -eq 0 ]; then

            IFS=',' read -r -a STATUS <<< "$RUN_FILE"

            # Parse pid
            PID=${STATUS[0]}

            # Parse running time
            CONN_START=${STATUS[1]}
            CONN_TIME_DIFF=$(( TIME_NOW - CONN_START ))
            CONN_TIME_STR=`printf '%02d:%02d:%02d' $(($CONN_TIME_DIFF/3600)) $(($CONN_TIME_DIFF%3600/60)) $(($CONN_TIME_DIFF%60))`

            PEER_TIME+=( $CONN_TIME_STR )

            #kill -0 $PID 2> /dev/null
            PID_ALIVE=`ps -p $PID | grep pppd`
            
            if [ "$PID_ALIVE" != "" ]; then
                PEER_PIDS+=( $PID )
                PEER_CONN_COUNT=$((PEER_CONN_COUNT+1))
            else
                PEER_PIDS+=( 0 )
            fi

        else
            PEER_PIDS+=( 0 )
            PEER_TIME+=( "" )
        fi
    done

}

function get_peer_pid()
{
    if [ "$1" == "" ]; then
        echo "Peer name must be specified."
        exit 1
    fi

    for I in "${!PEER_LIST[@]}"
    do
        if [ "${PEER_LIST[$I]}" == "$1" ]; then
            echo ${PEER_PIDS[$I]}
            return 0
        fi
    done

    echo "null"
}

function prompt_text_run()
{
    osascript <<EOT
    tell app "System Events"
      (display dialog "$2" default answer "$3" buttons {"$4", "$5"} default button 1 with title "$1")
    end tell
EOT
    return $?
}

function prompt_pwd_run()
{
    osascript <<EOT
    tell app "System Events"
      (display dialog "$2" default answer "$3" buttons {"$4", "$5"} default button 1 with hidden answer with title "$1")
    end tell
EOT
    return $?
}

function prompt_confirm()
{
    osascript <<EOT
    tell app "System Events"
      button returned of (display dialog "$2" buttons {"$3", "$4"} default button $5 with title "$1")
    end tell
EOT
    return $?
}

function error_dialog()
{
    osascript <<EOT
    tell app "System Events"
      display dialog "$2" buttons {"OK"} default button 1 with title "$1" with icon caution
    end tell
EOT
    return $?   
}

function prompt_text()
{
    RES=$(prompt_text_run "$1" "$2" "$3" "$4" "$5")
    BTN_LABEL_LEN=${#4}

    if [[ "$RES" == "button returned:$4"* ]]; then
        PREFIX=$((32+BTN_LABEL_LEN))
        NAME=${RES:$PREFIX}
        echo $NAME
    else
        exit 1
    fi
}

function prompt_pwd()
{
    RES=$(prompt_pwd_run "$1" "$2" "$3" "$4" "$5")
    BTN_LABEL_LEN=${#4}

    if [[ "$RES" == "button returned:$4"* ]]; then
        PREFIX=$((32+BTN_LABEL_LEN))
        NAME=${RES:$PREFIX}
        echo $NAME
    else
        exit 1
    fi
}

function update_keychain_entry()
{
    if [ ! -z "$2" ]; then
        security add-generic-password -a ${USER} -s "bitbar_pptp_$1" -l "BitBar PPTP: $1" -U -w "$2"
        PWD_RES=$?

        if [ $PWD_RES -ne 0 ]; then
            error_dialog "Error" "Failed to update credentials in the keychain."
            exit 1
        fi
    else
        security delete-generic-password -a ${USER} -s "bitbar_pptp_$1"
    fi
}

function get_keychain_entry()
{
    PWD=`security find-generic-password -a ${USER} -s "bitbar_pptp_$1" -w 2> /dev/null`
    RES=$?

    if [ "$RES" == "0" ]; then
        echo $PWD
    else
        echo ""
    fi
}

function run_pppd()
{
    pppd file "$RUN_DIR/$1.tmpcfg" >> "$LOG_DIR/$1.log" 2>> "$LOG_DIR/$1.log" &
    CONN_PID=$!
    CONN_TIME=`date +%s`

    echo "$CONN_PID,$CONN_TIME" > "$RUN_DIR/$1"
    exit 0
}

function connect()
{
    PID=$(get_peer_pid "$1")

    if [ "$PID" == "null" ]; then
        echo "Peer '$1' not found."
        exit 1
    elif [ "$PID" == "0" ]; then
        echo "Connecting to $1..."

        # Create temp config file
        TMP_CFG_FILE="$RUN_DIR/$1.tmpcfg"
        cp "$PEER_DIR/$1" "$TMP_CFG_FILE"

        # Get password
        PWD=$(get_keychain_entry "$1")
        
        if [ ! -z "$PWD" ]; then
            echo "password \"$PWD"\" >> "$TMP_CFG_FILE"
        fi

        CMD="$SELF_PATH connect_pppd \\\"$1\\\""
        echo $CMD
        osascript -e "do shell script \"$CMD\" with administrator privileges"

        sleep 1

        # Remove temp config
        rm "$TMP_CFG_FILE"

        exit 0
    else
        echo "Peer is already connected."
        exit 2
    fi
}

function disconnect()
{
    PID=$(get_peer_pid "$1")

    if [ "$PID" == "null" ]; then
        echo "Peer '$1' not found."
        exit 1
    elif [ "$PID" == "0" ]; then
        echo "Peer is not connected."
        exit 2
    else
        echo "Disconnecting from $1..."

        osascript -e "do shell script \"kill $PID\" with administrator privileges"
        RES=$?

        if [ $RES -eq 0 ]; then
            echo "Disconnected."
            sleep 3
        else
            echo "Failed to send kill signal to pppd: $RES"
            exit 1
        fi
    fi
}

function new_connection()
{
    # Get data
    NAME=$(prompt_text "Create new connection (1/6)" "Enter connection name" "My Connection" "Next" "Cancel")
    if [ -z "$NAME" ]; then exit 1; fi

    if [ -f "$PEER_DIR/$NAME" ]; then
        error_dialog "Error" "Connection with this name already exists."
        exit 1
    fi

    HOSTNAME=$(prompt_text "Create new connection (2/6)" "Enter server hostname" "vpn.mycompany.tld" "Next" "Cancel")
    if [ -z "$HOSTNAME" ]; then exit 1; fi

    USERNAME=$(prompt_text "Create new connection (3/6)" "Enter username" "" "Next" "Skip")
    
    if [ ! -z "$USERNAME" ]; then
        PASSWORD=$(prompt_pwd "Create new connection (4/6)" "Enter password" "" "Next" "Skip")
    fi
    
    USE_DEFAULT_ROUTE=$(prompt_confirm "Create new connection (5/6)" "Route all trafic via VPN?" "Yes" "No" 1)
    EDIT_CONFIG=$(prompt_confirm "Create new connection (6/6)" "All done, edit new configuration?" "Yes" "No" 1)

    echo "Name: $NAME"
    echo "Hostname: $HOSTNAME"
    echo "User: $USERNAME"
    echo "Default route: $USE_DEFAULT_ROUTE"
    
    # Add or remove keychain entry
    update_keychain_entry "$NAME" "$PASSWORD"

    cat <<EOF > "$PEER_DIR/$NAME"
plugin PPTP.ppp
noauth
redialcount 1
redialtimer 5
idle 1800
# mru 1368
# mtu 1368
receive-all
novj 0:0
ipcp-accept-local
ipcp-accept-remote
refuse-eap
refuse-pap
refuse-chap-md5
hide-password
mppe-stateless
mppe-128
looplocal
nodetach
usepeerdns
# ipparam gwvpn
# ms-dns 8.8.8.8
# require-mppe-128
debug

remoteaddress "$HOSTNAME"
EOF

    # Set username
    if [ ! -z "$USERNAME" ]; then
        echo "user \"$USERNAME\"" >> "$PEER_DIR/$NAME"
        echo "# DO NOT SET PASSWORD IN THIS FILE! Password is automatically apended from the keychain" >> "$PEER_DIR/$NAME"
    fi

    # Set default route
    if [ "$USE_DEFAULT_ROUTE" == "Yes" ]; then
        echo "defaultroute" >> "$PEER_DIR/$NAME"
    fi

    # Done
    echo "Created."

    # Edit config?
    if [ "$EDIT_CONFIG" == "Yes" ]; then
        /usr/bin/open -t "$PEER_DIR/$NAME"
    fi

    echo "Complete."
    exit 0
}

function rename_connection()
{
    if [ ! -f "$PEER_DIR/$1" ]; then
        echo "Configuration not found."
        exit 1
    fi

    PID=$(get_peer_pid "$1")

    if [ "$PID" != "null" ] && [ "$PID" != "0" ]; then
        echo "Connection is active, aborting..."
        exit 1
    fi

    NAME=$(prompt_text "Rename connection" "Enter connection name" "$1" "Rename" "Cancel")
    if [ -z "$NAME" ]; then exit 1; fi

    if [ -f "$PEER_DIR/$NAME" ]; then
        error_dialog "Error" "Connection with this name already exists."
        exit 1
    fi

    # Move files
    mv "$PEER_DIR/$1" "$PEER_DIR/$NAME"
    mv "$LOG_DIR/$1.log" "$LOG_DIR/$NAME.log" 2> /dev/null
    mv "$RUN_DIR/$1" "$RUN_DIR/$NAME" 2> /dev/null

    # Rename keychain
    PWD=$(get_keychain_entry "$1")
    
    if [ ! -z "$PWD" ]; then
        update_keychain_entry "$NAME" "$PWD"
        update_keychain_entry "$1" ""
    fi
}

function change_password()
{
    if [ ! -f "$PEER_DIR/$1" ]; then
        echo "Configuration not found."
        exit 1
    fi
    
    PASSWORD=$(prompt_pwd "Change password" "Enter new password" "" "Change password" "Cancel")

    if [ -z "$PASSWORD" ]; then
        
        RESET_PWD=$(prompt_confirm "Change password" "Delete current password?" "Yes" "No" 2)

        if [ "$RESET_PWD" == "Yes" ]; then
            update_keychain_entry "$1" ""
            echo "Password cleared."
        else
            echo "Nothing changed."
        fi

    else
        update_keychain_entry "$1" "$PASSWORD"
        echo "Password changed."
    fi
}

function delete_connection()
{
    if [ ! -f "$PEER_DIR/$1" ]; then
        echo "Configuration not found."
        exit 1
    fi

    CONFIRM=$(prompt_confirm "Delete connection" "Are you sure you want to delete connection '$1'?" "Yes" "No" 2)

    if [ "$CONFIRM" == "Yes" ]; then
        # Remove password
        update_keychain_entry "$1" ""

        # Remove files
        rm "$LOG_DIR/$1.log"
        rm "$PEER_DIR/$1"
        rm -f "$RUN_DIR/$1.tmpcfg"
        rm -f "$RUN_DIR/$1"
    fi
}

###
# Print menu to stdout
###
function printMenu()
{
    # Print toolbar line
    if [ "$PEER_CONN_COUNT" == "0" ]; then
        echo "🔒 VPN"
    else
        echo "🔒 VPN ($PEER_CONN_COUNT)"
    fi

    echo "---"

    # Print connected
    for I in "${!PEER_LIST[@]}"
    do
        if [ "${PEER_PIDS[$I]}" != "0" ]; then
            echo "${PEER_LIST[$I]} (${PEER_TIME[$I]}) | color=green"
            echo "-- Disconnect (PID: ${PEER_PIDS[$I]}) | color=red terminal=false bash=\"$SELF_PATH\" param1=disconnect param2=\"${PEER_LIST[$I]}\" refresh=true"
            echo "-----"
            echo "-- Rename"
        else
            echo "${PEER_LIST[$I]}"
            echo "-- Connect | terminal=false bash=\"$SELF_PATH\" param1=connect param2=\"${PEER_LIST[$I]}\" refresh=true"
            echo "-----"
            echo "-- Rename | terminal=false bash=\"$SELF_PATH\" param1=rename param2=\"${PEER_LIST[$I]}\" refresh=true"
        fi

        echo "-- Change password | terminal=false bash=\"$SELF_PATH\" param1=change_pwd param2=\"${PEER_LIST[$I]}\" refresh=true"
        echo "-- Open log | terminal=false bash=/usr/bin/open param1=\"$LOG_DIR/${PEER_LIST[$I]}.log\""
        echo "-- Edit config | terminal=false bash=/usr/bin/open param1=-t param2=\"$PEER_DIR/${PEER_LIST[$I]}\""
        echo "-----"
        echo "-- Delete | terminal=false bash=\"$SELF_PATH\" param1=delete param2=\"${PEER_LIST[$I]}\" refresh=true"
    done

    echo "---"
    echo "Add new connection | terminal=false bash=\"$SELF_PATH\" param1=new refresh=true"

    echo "---"
    echo "Settings"
    echo "-- Open peers directory | terminal=false bash=/usr/bin/open param1=\"$PEER_DIR\""
    echo "-- Open logs directory | terminal=false bash=/usr/bin/open param1=\"$LOG_DIR\""

}

# Load list
load_list

# Check command
case "$1" in

    # Connect
    "connect" ) connect "$2";;

    # Run pppd process
    "connect_pppd" ) run_pppd "$2";;

    # Disconnect
    "disconnect" ) disconnect "$2";;

    # Create a new connection
    "new" ) new_connection;;

    # Rename connection
    "rename" ) rename_connection "$2";;

    # Change password
    "change_pwd" ) change_password "$2";;

    # Delete connection
    "delete" ) delete_connection "$2";;

    # No command
    "" ) printMenu;;

    # Undefined
    *) echo "Undefined command '$1'."; exit 1;;

esac