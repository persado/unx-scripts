#!/bin/bash
AMQ_BIN=/opt/activemq/bin
ACTIVEMQ_HOME=/opt/activemq
ACTIVEMQ_BASE=$ACTIVEMQ_HOME
AHOST="http://localhost:8161/admin"

PRGURL=$( curl $AHOST/queues.jsp|grep DLQ.inbound|grep purge| awk 'BEGIN { FS = "\"" }; {print $2}' )
DLQ=$( curl $AHOST/xml/queues.jsp |grep -A 2 name=\"DLQ.inbound|tail -1|awk 'BEGIN { FS = "\"" }; {print $2}' )
PURL="$AHOST/$PRGURL"
echo "`date` DLQ Found: $DLQ"
echo "Purge URL = $PURL"
if [ $DLQ -gt 500000 ];
then
	echo "Will now ask to purge DLQ"
	curl "$PURL"
fi
