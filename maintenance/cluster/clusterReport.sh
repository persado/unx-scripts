#!/bin/bash

#warning is issued if %used is over this
PCTWARN=30
PCTFAIL=45

function diskSpace() {

   echo -n "host $1 : mount /$2" >> $1.log
   ssh mongo@$1 \
     "df -h | grep /$2 " > .tmp 2>/dev/null
   availspace=`cat .tmp|awk '{print $3}' `
   space=`cat .tmp| awk '{print $1}' `
   usedpct=`cat .tmp| awk '{print $4}' `
   used=$(cat .tmp| awk '{print $4}' |cut -c 1- ) 
   echo -n " : $availspace free out of $space : used $usedpct" >> $1.log

   if [[ $used > $PCTFAIL ]] ;
   then
      echo " ****FAILURE IMMINENT**** CANNOT COMPACT! " >> $1.log
   elif [[ $used > $PCTWARN ]] ; 
   then 
      echo " WARNING " >> $1.log
   else
      echo " " >> $1.log
   fi   

   tail -1 $1.log
}





for p in $(cat hosts.cfg) 
do
   rm -f $p.log>/dev/null
   diskSpace $p data
done 

