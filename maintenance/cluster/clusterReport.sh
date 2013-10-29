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
      echo -n " ****FAILURE IMMINENT**** CANNOT COMPACT AUTOMATICALLY! " >> $1.log
      CAN_COMPACT=0
   elif [[ $used > $PCTWARN ]] ; 
   then 
      echo -n " WARNING " >> $1.log
      CAN_COMPACT=1
   else
      echo -n " " >> $1.log
      CAN_COMPACT=1
   fi   

   tail -1 $1.log && echo ""
}

function isPrimary() {
   echo -n "!" >> $1.log
   ssh mongo@$1 \
     "/opt/mongodb/bin/mongo localhost:27017/admin --quiet --eval 'rs.isMaster().secondary'  " > .tmp 2>/dev/null
   secondary=`cat .tmp`
   if [ "$secondary" = "true" ] ;
   then 
      echo "$1 [S]"
      PRIMARY=0
      echo -n " [SECONDARY] " >> $1.log
      echo -n "$1 is SECONDARY - "
      if [[ $CAN_COMPACT > 0 ]] ; 
      then 
         echo  "CAN BE AUTO-COMPACTED"
      else 
         echo  "COMPACT NOT POSSIBLE"
      fi
   else
      echo "$1 [P]"
      PRIMARY=1
      echo " [PRIMARY] " >> $1.log
   fi
}

function compactSecondary() {
   if [[ $CAN_COMPACT > 0 && $PRIMARY < 1 ]] ;
   then
      echo " ---> adding $1 to compact configuration"
      echo "$1" >> compact.cfg
   elif [[ $CAN_COMPACT < 1 && $PRIMARY < 1 ]] ;
   then
      echo " ---> $1 is not to be compacted automatically"
      echo "#$1" >> compact.cfg
   fi
}


rm -f compact.cfg
for p in $(cat hosts.cfg) 
do
   rm -f $p.log>/dev/null
   diskSpace $p data
   isPrimary $p
   compactSecondary $p
   echo "" >> $p.log 
done 


echo "-----------------------------------------" 
echo "the following nodes need to be compacted:"
cat compact.cfg
