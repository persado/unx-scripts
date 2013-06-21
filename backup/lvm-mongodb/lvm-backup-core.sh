#!/bin/bash
#
# lvsbackup.sh - backup a mongo secondary by rsync/tgz
#
# LICENSE
#
# Copyright (c) 2013, Thanos Angelatos agelatos@gmail.com
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#    * Redistributions of source code must retain the above copyright
#      notice, this list of conditions and the following disclaimer.
#    * Redistributions in binary form must reproduce the above copyright
#      notice, this list of conditions and the following disclaimer in the
#      documentation and/or other materials provided with the distribution.
#    * Neither the name of the Thanos Angelatos nor the
#      names of its contributors may be used to endorse or promote products
#      derived from this software without specific prior written permission.
#
#THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
#ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
#WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
#DISCLAIMED. IN NO EVENT SHALL Thanos Angelatos BE LIABLE FOR ANY
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

#
# ****** CONFIGURATION
#
if [ ! -f ~/lvm-backup-config ]; 
then 
	echo " "
	echo "$0 needs configuration file lvm-backup-config @ the user home directory. Please configure and retry"
	echo " "
	exit 199
fi

source ~/lvm-backup-config

if [ ! -f "$AWS" ];
then
	echo " "
	echo "lvsbackup needs AWS script for AWS connectivity. Install via the following commands:"
	echo "# curl https://raw.github.com/timkay/aws/master/aws -o aws "
	echo "# chmod +x aws"
	exit 200
else
	if [ ! -f ~/.awssecret ];
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
# if PARANOIDMODE is "Y" then this will ask
# your mongo to clean up and flush everything to disk
# This is the safest option by far - but in the backup you still
# need to remove the mongod.lock file. Check docs.
#
fsyncLock() {
	if [ "x$PARANOIDMODE" == "xY" ]
	then
		echo "db.fsyncLock(); " > script.js
		$MONGO $1/admin script.js
		RET=$?
		if [ $RET = 0 ]
		then
 			echo "PARANOID: Locked mongodb on $1"
		else
			echo "********************************************************************"
			echo "PARANOID: Failed to lock $1, (got $RET back) PANIC!"
			echo "********************************************************************"
			exit $RET
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
		echo "db.fsyncUnlock(); " > script.js
		$MONGO $1/admin script.js
		RET=$?
		if [ $RET = 0 ]
		then
 			echo "PARANOID: Unlocked mongodb" on $1
		else
			echo "********************************************************************"
			echo "PARANOID: Failed to unlock $1, (got $RET back) PANIC!"
			echo "********************************************************************"
			exit $RET
		fi
	fi

}

#
# creates and mounts the snapshot.
#
createAndMountSnapshot() {

	fsyncLock "$HOSTPORT"
	#fsyncLock "$HOSTPORTC"

	/sbin/lvcreate -L$SNAPSIZE -s -n $BACKUPSNAP $BACKUPVOL
	RET=$?
	if [ $RET = 0 ]
 	then
		echo "Snapshot $BACKUPSNAP created"
		unlock "$HOSTPORT"
		#unlock "$HOSTPORTC"
	else
		echo "Snapshot $BACKUPSNAP failed!!"
		unlock "$HOSTPORT"
		#unlock "$HOSTPORTC"
		exit $RET
	fi
	if [ ! -d $BACKUPSNAPMOUNT ]
	then
		mkdir $BACKUPSNAPMOUNT
	fi
	mount $MOUNTOPTS $BACKUPSNAP $BACKUPSNAPMOUNT
	RET=$?
	if [ $RET = 0 ]
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
	if [ $? = 0 ]
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
	$AWS put "$S3BUCKET" "$FNAME"
	if [ $? = 0 ]
	then
		echo "s3put succeeded! File $FINALFILE is now in $S3BUCKET "
	else
		echo "s3put failed!!!!!!! will retry once:"
		$AWS put "$S3BUCKET" "$FNAME"
		if [ $? = 0 ]
        	then
                	echo "s3put succeeded! File $FINALFILE is now in $S3BUCKET "
        	else
                	echo "s3put failed!!!!!!! - no more retries - backup not in S3"
		fi
	fi
	if [ "$KEEPWEEKLY" = "Y" ]
	then
		if [ "$DATE" = "sun" ]
		then
			WEEK=`date +%W`
			WEEKFILE="$BACKUPTARGET/backup/backup-`hostname -s`-week$WEEK.tgz"
			rm -f $WEEKFILE
			cp "$FINALFILE" "$WEEKFILE"
			$AWS copy "$S3BUCKET/$WEEKFILE" "/$S3BUCKET/$FINALFILE"
			echo "Copied $FINALFILE as week backup of week $WEEK: $WEEKFILE"
		fi
	fi
}


rsyncBackup() {

	/usr/bin/rsync $RSYNCOPTS $BACKUPSNAPMOUNT $BACKUPTARGET/backup
	if [ $? = 0 ]
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