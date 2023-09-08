#/bin/bash

#Killing a process by name, you need to pass the process name like:
#KillByName ping

# Check if the argument is provided
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <process-name>"
    exit 1
fi

# Get the process name from the argument
PROCESS_NAME="$1"

# Use pkill to kill the process by name
pkill "$PROCESS_NAME"

# Check the success status of pkill
if [ $? -eq 0 ]; then
    echo "Successfully killed process(es) with name: $PROCESS_NAME"
else
    echo "Failed to kill process(es) with name: $PROCESS_NAME"
fi

