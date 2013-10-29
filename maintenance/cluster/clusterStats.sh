#!/bin/bash

function clusterStats() {
   (ssh mongo@$1 \
     "/opt/mongodb/bin/mongostat --noheaders -n 1 " > .tmp 2>/dev/null ;
   stats=`cat .tmp|tail -1 | awk '{ print "PF" $11 " L " $12 " q " $14 " a " $15 }'` ;
   echo "$1 $stats" ) &
}
for p in $(cat hosts.cfg) 
do
   clusterStats $p
done 
echo "Waiting for results" 
sleep 30
