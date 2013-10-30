#!/bin/bash
#
# AMQ Host
AHOST="http://localhost:8161/admin"
# Default Queue
QUEUE="DLQ.inbound"
# Limit - if exceeded, purge
COUNT=500000

# first argument is the queue name
if [ ! -z "$1" ]; 
then
	QUEUE="$1"
fi
# second argument is the limit
if [ ! -z "$2" ];
then	
	COUNT=$2
fi

echo "AMQ Queue Purge"
echo "Usage: $0 [Queue to monitor] [limit to start purging]"
echo " "
echo -n "Working ."
PRGURL=$( curl $AHOST/queues.jsp 2>/dev/null |grep $QUEUE |grep purge| awk 'BEGIN { FS = "\"" }; {print $2}' )
echo -n ".."
MSGS=$( curl $AHOST/xml/queues.jsp 2>/dev/null |grep -A 2 name=\"$QUEUE |tail -1|awk 'BEGIN { FS = "\"" }; {print $2}' )
echo ".."
PURL="$AHOST/$PRGURL"

echo "QUEUE = $QUEUE"
echo "LIMIT = $COUNT"
if [ "x" != "x$MSGS" ]; 
then
	echo "FOUND = $MSGS"
	if [ $MSGS -gt $COUNT ];
	then
		echo "Found $MSGS messages over the limit ($COUNT) : now asking to purge $QUEUE - please wait...."
		curl "$PURL"
		echo "$QUEUE should now be empty."
	else
		echo "$QUEUE has $MSGS messages. Not purging."
	fi
else
	echo "No messages found, connectivity/network error? ActiveMQ should be alive in address $AHOST"
fi
