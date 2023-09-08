#/bin/bash

#Killing a process per process Id"
#KillByPid 100
echo "Killing a process per process Id: $(kill $1)"

# Check if the argument is provided
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <process-id>"
    exit 1
fi

# Get the process ID from the argument
PROCESS_ID="$1"

# Use kill command to kill the process by its PID
kill "$PROCESS_ID"

# Check the success status of kill
if [ $? -eq 0 ]; then
    echo "Successfully killed process with PID: $PROCESS_ID"
else
    echo "Failed to kill process with PID: $PROCESS_ID"
fi
