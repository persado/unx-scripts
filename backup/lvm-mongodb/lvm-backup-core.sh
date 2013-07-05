#!/bin/bash
#
# lvsbackup.sh - backup a mongo secondary by rsync/tgz
#
# LICENSE
#
# Copyright (c) 2013, Persado SA (persado.com) & A. Angelatos 
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#    * Redistributions of source code must retain the above copyright
#      notice, this list of conditions and the following disclaimer.
#    * Redistributions in binary form must reproduce the above copyright
#      notice, this list of conditions and the following disclaimer in the
#      documentation and/or other materials provided with the distribution.
#    * Neither the name of Persado SA or A. Angelatos nor the
#      names of its contributors may be used to endorse or promote products
#      derived from this software without specific prior written permission.
#
#THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
#ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
#WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
#DISCLAIMED. IN NO EVENT SHALL Persado SA or A. Angelatos BE LIABLE FOR ANY
#DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
#(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
#LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
#ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
#(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
#SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#
# DESCRIPTION
#
# This script will backup a mongo db instance to a different location
# using rsync or other methods. To be extra-safe, enabling PARANOIDMODE will make the script
# ask mongodb to "fsync and lock" - which will flush all journal and files
# to disk, making it a 100% safe backup. Use PARANOIDMODE only on a secondary
# of a replica set. WARNING: Using "fsync and lock" on a primary will make your
# primary queue and eventually reject writes given a certain load. Usually
# a snapshot at LVM level is not more than 1-2 seconds but you have been warned.
#
# Ideally this script should be executed at night via cron - you need to monitor and
# make sure that backup is complete before your "normal backup procedure" takes over.
# The script will remove the snapshot when done, so you may check if the snapshot
# is still alive as an indication that the script is still working.
#


echo "About to start, this script will pivot to the root home"
cd /root
echo "Now at `pwd` - reading config"


##
## warning: the following bit will check the existence of an older version and migrate the
## configuration there. It should only happen once.
if [ ! -f ".migrated-lvm-backup" ]; # migration is needed
then
    echo "migrator: about to migrate from old version"
	sed -e '1,/CONFIGURATION/d' lvsbackup-data.sh | sed -e '/^fi$/,$d' - > config
	echo "fi" >> config
	mv config lvm-backup-config
	touch .migrated-lvm-backup
	echo "migrator: $0 migrated config data"
	cp -f lvsbackup-data.sh .lvsbackup-data.sh.original
	cp $0 lvsbackup-data.sh
	echo "migrator: migrated ourselves to proper location"
	./lvsbackup-data.sh
	exit 0
fi

##
## auto-update: if the updated is different, we will execute that instead.
##
rm -f lvm-backup-core.sh
wget "https://raw.github.com/persado/unx-scripts/master/backup/lvm-mongodb/lvm-backup-core.sh"
if [ ! -f "lvm-backup-core.sh" ]; 
then
	echo "auto-update: WARNING! auto-update has failed, check location!!!"
else
	if diff lvm-backup-core.sh lvsbackup-data.sh >/dev/null ; then
		echo "auto-update: no update is necessary"
	else 
		echo "auto-update: new version found!"
		mv lvm-backup-core.sh lvsbackup-data.sh
		chmod +x lvsbackup-data.sh
		echo "auto-update: will restart now!"
		./lvsbackup-data.sh
		exit 0
	fi
fi

##
## logrotate configuration - if logrotate stuff not found, we add
## to the daily cron trigger
## to change the configuration (reapplying it) just increase the 
## version check number below
LOGROTATE_VERSION=1
##
if [ ! -f ".logrotate.v$LOGROTATE_VERSION" ];
then
	cat > /etc/logrotate.d/mongodb <<EOF
/applogs/mongo/mongo*.log {
	daily
	missingok
	rotate 7
	compress
	delaycompress
	notifempty
	create 640 mongodb mongodb
	sharedscripts
	postrotate
		killall -SIGUSR1 `pidof mongod`
		find /applogs/mongo/ -type f -regex ".*\.\(log.[0-9].*-[0-9].*\)" -exec rm {} \;
	endscript
}
EOF
	echo "logrotate configuration added at /etc/logrotate.d/mongodb"
fi


#
# ****** CONFIGURATION
#
if [ ! -f "lvm-backup-config" ]; 
then 
	echo " "
	echo "$0 needs configuration file lvm-backup-config @ the user home directory. Please configure and retry"
	echo " "
	exit 199
fi

source lvm-backup-config

if [ ! -f "$AWS" ];
then
	echo " "
	echo "lvsbackup needs AWS script for AWS connectivity. Install via the following commands:"
	echo "# curl https://raw.github.com/timkay/aws/master/aws -o aws "
	echo "# chmod +x aws"
	exit 200
else
	if [ ! -f ".awssecret" ];
	then
		echo "ERROR: .awssecret not configured"
		exit 201
	fi
fi

echo "********************************************************************"
echo " Backup script using lvm snapshots on mongo"
echo " "
echo " WARNING !!! USE THIS ONLY ON A SECONDARY NODE !!! WARNING"
echo " "
echo " Configured: "
echo "     PARANOID=$PARANOIDMODE (Y enables fsync+lock, N goes topless)"
echo "     FAILIFPRIMARY=$FAILIFPRIMARY (Y fails if this node is a Primary)"
echo "     Source $BACKUPSRC volume $BACKUPVOL"
echo "     Target $BACKUPTARGET snapshot mount $BACKUPSNAPMOUNT"
echo "     Snapshot size to use $SNAPSIZE"
echo "     main mongo command : '$MONGO $HOSTPORT/admin'"
echo "     aws executable : $AWS"
echo " "
echo "********************************************************************"
echo " "



#
# function to unmount and kill the snapshot,
# removing the used space in the process.
# Remember: LVM works on COW principles, so you dont need
# the full space for a snapshot - only differences are stored.
#
unmountSnapshot() {
	if [ -e $BACKUPSNAP ]
	then
		/bin/umount $BACKUPSNAPMOUNT
		echo "Snapshot $BACKUPSNAP unmounted from $BACKUPSNAPMOUNT"
  		/sbin/lvremove -f $BACKUPSNAP
		echo "Snapshot $BACKUPSNAP removed."
	else
		echo "Snapshot not there, nothing to clean"
	fi
}

#
# updates the locked variable with a 'islocked' check
#
checkLocked() {
	LOCKED=`$MONGO $1/admin --quiet --eval "printjson(db.currentOp().fsyncLock)"`
}

#
# if PARANOIDMODE is "Y" then this will ask
# your mongo to clean up and flush everything to disk
# This is the safest option by far - but in the backup you still
# need to remove the mongod.lock file. Check docs.
#
fsyncLock() {
	if [ "x$PARANOIDMODE" == "xY" ]
	then
		checkLocked $1
		if [ "$LOCKED" == "true" ] 
		then 
			echo "********************************************************************"
			echo "DB IS LOCKED ALREADY. NOT TRYING TO LOCK AGAIN"
			echo "********************************************************************"
		else
			echo "db.fsyncLock(); " > script.js
			$MONGO $1/admin script.js
			RET=$?
			if [ $RET -eq 0 ]
			then
	 			echo "PARANOID: Locked mongodb on $1"
			else
				echo "********************************************************************"
				echo "PARANOID: Failed to lock $1, (got $RET back) PANIC!"
				echo "********************************************************************"
				#exit $RET
			fi
		fi
	fi
}

#
# if PARANOIDMODE is "Y" this will unlock the DB.
# In case of error, it will fail the script - and your DB
# will be locked. Make it notify you via email if this happens
#
unlock() {
	if [ "x$PARANOIDMODE" == "xY" ]
	then
		checkLocked $1
		if [ "$LOCKED" == "false" ] 
		then 
			echo "********************************************************************"
			echo "DB IS UNLOCKED. NOT TRYING TO UNLOCK"
			echo "********************************************************************"
		else
			echo "db.fsyncUnlock(); " > script.js
			$MONGO $1/admin script.js
			RET=$?
			if [ $RET -eq 0 ]
			then
	 			echo "PARANOID: Unlocked mongodb" on $1
			else
				echo "********************************************************************"
				echo "PARANOID: Failed to unlock $1, (got $RET back) PANIC!"
				echo "********************************************************************"
				#exit $RET
			fi
		fi
	fi

}

#
# creates and mounts the snapshot.
#
createAndMountSnapshot() {

	fsyncLock "$HOSTPORT"
	
	if [ "xx$HOSTPORTC" == "xx" ] 
	then 
		echo "Additional Host not defined"
	else 
		fsyncLock "$HOSTPORTC"
	fi
	
	/sbin/lvcreate -L$SNAPSIZE -s -n $BACKUPSNAP $BACKUPVOL
	RET=$?
	if [ $RET -eq 0 ]
 	then
		echo "Snapshot $BACKUPSNAP created"
		unlock "$HOSTPORT"
		if [ "xx$HOSTPORTC" == "xx" ] 
		then 
			echo "Additional Host not defined"
		else 
			unlock "$HOSTPORTC"
		fi
	else
		echo "Snapshot $BACKUPSNAP failed!!"
		unlock "$HOSTPORT"
		if [ "xx$HOSTPORTC" == "xx" ] 
		then 
			echo "Additional Host not defined"
		else 
			unlock "$HOSTPORTC"
		fi
		exit $RET
	fi
	
	
	if [ ! -d $BACKUPSNAPMOUNT ]
	then
		mkdir $BACKUPSNAPMOUNT
	fi
	mount $MOUNTOPTS $BACKUPSNAP $BACKUPSNAPMOUNT
	RET=$?
	if [ $RET -eq 0 ]
	then
		echo "Mounted $BACKUPSNAP on $BACKUPSNAPMOUNT successfully"
	else
		echo "$BACKUPSNAP cannot be mount to $BACKUPSNAPMOUNT"
		exit $RET
	fi
}

tgzBackup() {
	#check if #backup folder exists
	mkdir -p $BACKUPTARGET/backup
	rm -fr $BACKUPTARGET/backup/current.tgz
	tar cvfz $BACKUPTARGET/backup/current.tgz $BACKUPSNAPMOUNT/*
	if [ $? -eq 0 ]
	then
		echo "tgz backup completed at $BACKUPTARGET/backup/current.tgz"
		ORIGFILE="$BACKUPTARGET/backup/current.tgz"
		FNAME="backup-`hostname -s`-$DATE.tgz"
		FINALFILE="$BACKUPTARGET/backup/$FNAME"
		rm -fr $FINALFILE
		mv "$ORIGFILE" "$FINALFILE"
	else
		echo " "
		echo "********************************************************************"
		echo "WARNING! Backup was interrupted and volume not copied completely!"
		echo "********************************************************************"
		echo " "
	fi

}



s3copy() {
	echo "About to copy $FINALFILE to S3"
	cd $BACKUPTARGET/backup
	if [ ! -f $FNAME ]
	then
		echo "$FNAME not found, fail to copy!!!"
		exit 205
	fi
	$AWS put "$S3BUCKET/$DATE/$FNAME" "$FNAME"
	if [ $? -eq 0 ]
	then
		echo "s3put succeeded! File $FINALFILE is now in $S3BUCKET/$DATE "
	else
		echo "s3put failed!!!!!!! will retry once:"
		$AWS put "$S3BUCKET/$DATE/$FNAME" "$FNAME"
		if [ $? -eq 0 ]
        	then
                	echo "s3put succeeded! File $FINALFILE is now in $S3BUCKET/$DATE "
        	else
                	echo "s3put failed!!!!!!! - no more retries - backup not in S3"
		fi
	fi
	if [ "$KEEPWEEKLY" == "Y" ]
	then
		if [ "$DATE" == "sun" ]
		then
			WEEK=`date +%W`
			WEEKFILE="$BACKUPTARGET/backup/backup-`hostname -s`-week$WEEK.tgz"
			rm -f $WEEKFILE
			cp "$FINALFILE" "$WEEKFILE"
			$AWS put "$S3BUCKET/$WEEK/$FNAME" "$FNAME"
			echo "Copied $FINALFILE as week backup of week $WEEK: $WEEKFILE"
		fi
	fi
}


rsyncBackup() {

	/usr/bin/rsync $RSYNCOPTS $BACKUPSNAPMOUNT $BACKUPTARGET/backup
	if [ $? -eq 0 ]
	then
		echo "Rsync backup completed."
	else
		echo " "
		echo "********************************************************************"
		echo "WARNING! Backup was interrupted and volume not copied completely!"
		echo "********************************************************************"
		echo " "
	fi

}

checkIfPrimary() {

	is_secondary=$($MONGO $HOSTPORT/admin --quiet --eval 'rs.isMaster().secondary')
	if [ "$is_secondary" == "true" ]
	then
		echo "Secondary node - backup can proceed"
	else
		if [ "$FAILIFPRIMARY" == "Y" ]
		then
			echo "PRIMARY !!! Primary backup is dangerous, bailing out "
			exit 50
		else
			echo "PRIMARY !!! WARNING !!! BACKUP WILL CONTINUE !!! DANGER !!!"
		fi
	fi
}


echo " "
echo -n "Checking node $HOSTPORT status: "
checkIfPrimary
echo "Starting backup at `date`"
echo " "
unmountSnapshot
echo " "
createAndMountSnapshot
echo " "
echo "about to backup the volume...."
echo " "
tgzBackup
echo " "
echo "volume backup complete"
echo " "
unmountSnapshot
echo " "
echo "Copy to S3 started (file=$FINALFILE) at `date`"
s3copy
echo "Copy to S3 completed at `date`"
echo " "
echo "All done - finished at `date`."
